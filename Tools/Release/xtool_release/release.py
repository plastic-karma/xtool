"""Build, assemble, verify and optionally upload manifest-driven releases."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

from .shortcut_model import write_model
from .signing import load_signing
from .verify import macho_slices, verify, verify_adhoc


def native_home():
    return Path(os.environ.get('XTOOL_NATIVE_HOME') or
                Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'xtool/native').expanduser().resolve()


def run(command, *, cwd=None, env=None, private=False):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                            capture_output=True, check=False)
    if not private:
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
    if result.returncode:
        raise RuntimeError(f'{Path(command[0]).name} failed (exit {result.returncode})')
    return result.stdout


def bundle_paths(project):
    targets = {t['name']: t for t in project['targets']}
    paths = {}
    def path(name):
        if name in paths:
            return paths[name]
        target = targets[name]
        if target['parent'] is None:
            value = Path('.')
        else:
            parent = path(target['parent'])
            if target['kind'] == 'extension':
                value = parent / 'PlugIns' / (target['module'] + '.appex')
            elif target['platform'] == 'watchos':
                value = parent / 'Watch' / (target['module'] + '.app')
            else:
                raise ValueError(f'Unsupported embedded application: {name}')
        paths[name] = value
        return value
    for name in targets:
        path(name)
    if len(set(paths.values())) != len(targets):
        raise ValueError('Duplicate output bundle paths')
    return paths


def compiler_environment(project, toolchain=None):
    environment = os.environ.copy()
    version = project['release'].get('swiftVersion')
    if toolchain:
        root = Path(toolchain).expanduser().resolve()
        candidates = [root, root / 'bin', root / 'usr/bin']
    elif version:
        swiftly = Path(os.environ.get('SWIFTLY_HOME_DIR') or
                       Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'swiftly')
        candidates = [swiftly / 'toolchains' / str(version) / 'usr/bin']
    else:
        return environment
    binary_dir = next((p for p in candidates if (p / 'swift').is_file()), None)
    if binary_dir is None:
        raise ValueError('Requested Swift toolchain is not installed; install it with Swiftly or use --toolchain')
    environment['PATH'] = str(binary_dir) + os.pathsep + environment.get('PATH', '')
    return environment


def sdk_version_number(version):
    parts = [int(p) for p in str(version).split('.')]
    if not 1 <= len(parts) <= 3 or any(p < 0 or p > 255 for p in parts):
        raise ValueError(f'Invalid SDK/deployment version: {version}')
    parts += [0] * (3 - len(parts))
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def sdk_metadata(sdk, target):
    platform = 'WatchOS' if target['platform'] == 'watchos' else 'iPhoneOS'
    root = sdk / f'Developer/Platforms/{platform}.platform/Developer/SDKs/{platform}.sdk'
    settings = json.loads((root / 'SDKSettings.json').read_text())
    system = plistlib.loads((root / 'System/Library/CoreServices/SystemVersion.plist').read_bytes())
    return {'DTPlatformName': 'watchos' if target['platform'] == 'watchos' else 'iphoneos',
            'DTPlatformVersion': settings['Version'], 'DTPlatformBuild': system['ProductBuildVersion'],
            'DTSDKName': settings['CanonicalName'], 'DTSDKBuild': system['ProductBuildVersion'],
            'CFBundleSupportedPlatforms': [platform]}


def check_inventory(app, project, paths):
    found = {Path('.')} | {p.relative_to(app) for p in app.rglob('*') if p.suffix in ('.app', '.appex')}
    expected = set(paths.values())
    if found != expected:
        raise ValueError(f'Bundle inventory mismatch; missing={sorted(map(str, expected - found))}, unexpected={sorted(map(str, found - expected))}')
    for target in project['targets']:
        bundle = app / paths[target['name']]
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != target['bundleID'] or info['CFBundleExecutable'] != target['module']:
            raise ValueError(f'Bundle identity mismatch: {target["name"]}')
        if str(info['CFBundleVersion']) != str(project['buildNumber']):
            raise ValueError(f'Bundle build mismatch: {target["name"]}')
        expected_version = target['info'].get('CFBundleShortVersionString')
        if expected_version and info['CFBundleShortVersionString'] != expected_version:
            raise ValueError(f'Bundle marketing version mismatch: {target["name"]}')
        if sdk_version_number(info['MinimumOSVersion']) != sdk_version_number(target['minimumOS']):
            raise ValueError(f'Bundle minimum OS mismatch: {target["name"]}')


def prepare_bundle(bundle, target, sdk, native, generated, install_name_tool):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    catalogs = target['assetCatalogs']
    if catalogs:
        output = generated / target['module'] / 'assets'
        command = [native / 'bin/xtool-native-assets', catalogs[0], target['platform'], output,
                   '--deployment-target', target['minimumOS']]
        if target.get('appIcon'):
            command += ['--app-icon', target['appIcon']]
        for catalog in catalogs[1:]:
            command += ['--catalog', catalog]
        run(command)
        info.update(plistlib.loads((output / 'asset-info.plist').read_bytes()))
        shutil.copy2(output / 'Assets.car', bundle / 'Assets.car')
        for icon in output.glob('*.png'):
            shutil.copy2(icon, bundle / icon.name)
    if target['appIntents']:
        output = generated / target['module'] / 'Metadata.appintents'
        display = info.get('CFBundleDisplayName', info.get('CFBundleName', target['name']))
        command = [native / 'bin/xtool-appintents-gen', '--module', target['module'], '--bundle-id', target['bundleID'],
                   '--display-name', display, '--output', output, '--platform', target['platform'],
                   '--deployment-target', target['minimumOS']]
        if target['kind'] == 'extension':
            command += ['--app-extension']
        for source in target['sources']:
            command += ['--source', source]
        run(command)
        actions = json.loads((output / 'extract.actionsdata').read_text())
        if actions.get('autoShortcuts'):
            write_model(actions, target['bundleID'], display, int(time.time() * 1000), output / 'nlu', native / 'lib/liblzfse.so')
        shutil.copytree(output, bundle / 'Metadata.appintents', dirs_exist_ok=True)
    info.update(sdk_metadata(sdk, target))
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    executable = bundle / info['CFBundleExecutable']
    host_paths = set()
    for _, _, _, commands in macho_slices(executable.read_bytes()):
        for kind, body in commands:
            if kind == 0x8000001c:
                offset = struct.unpack_from('<I', body, 8)[0]
                value = body[offset:].split(b'\0', 1)[0].decode()
                if value.startswith('/') and not value.startswith(('/usr/lib/', '/System/Library/')):
                    host_paths.add(value)
    for path in sorted(host_paths):
        run([install_name_tool, '-delete_rpath', path, executable])
    return len(host_paths)


def check_platforms(app, project, paths, sdk):
    evidence = []
    for target in project['targets']:
        bundle = app / paths[target['name']]
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        watch = target['platform'] == 'watchos'
        slices = macho_slices((bundle / info['CFBundleExecutable']).read_bytes())
        expected_cpus = {0x200000c, 0x100000c} if watch else {0x100000c}
        if {s[0] for s in slices} != expected_cpus or len(slices) != len(expected_cpus):
            raise ValueError(f'Missing or unexpected architecture: {target["name"]}')
        metadata = sdk_metadata(sdk, target)
        if info['CFBundleSupportedPlatforms'] != metadata['CFBundleSupportedPlatforms']:
            raise ValueError(f'Incorrect bundle platform: {target["name"]}')
        for cpu, _, _, commands in slices:
            records = [struct.unpack_from('<III', body, 8) for kind, body in commands if kind == 0x32]
            minimum = max(sdk_version_number(target['minimumOS']), sdk_version_number('26.0')) if watch and cpu == 0x100000c else sdk_version_number(target['minimumOS'])
            expected = [(4 if watch else 2, minimum, sdk_version_number(metadata['DTPlatformVersion']))]
            if records != expected:
                raise ValueError(f'Architecture platform/deployment/SDK mismatch: {target["name"]} {hex(cpu)}: {records} != {expected}')
            for kind, body in commands:
                if kind in (0xc, 0x80000018, 0x8000001c, 0x8000001f):
                    start = struct.unpack_from('<I', body, 8)[0]
                    value = body[start:].split(b'\0', 1)[0].decode()
                    if value.startswith('/') and not value.startswith(('/System/Library/', '/usr/lib/')):
                        raise ValueError(f'Host load path in {target["name"]}')
                    if 'SwiftUICore.framework' in value:
                        raise ValueError(f'Private framework linkage in {target["name"]}')
        evidence.append({'identifier': target['bundleID'], 'architectures': [hex(s[0]) for s in slices]})
    return evidence


def upload_release(record, options, destination, asc):
    app_id = options.get('appID')
    if not app_id:
        raise ValueError('--upload requires appStoreConnect.appID')
    command = [asc, 'builds', 'upload', '--app', str(app_id), '--ipa', record['ipa'], '--wait', '--output', 'json']
    if options.get('testNotes'):
        command += ['--test-notes', options['testNotes'], '--locale', options.get('locale', 'en-US')]
    receipt = json.loads(run(command, private=True))
    (destination / 'upload.json').write_text(json.dumps(receipt, indent=2) + '\n')
    response = json.loads(run([asc, 'builds', 'list', '--app', str(app_id), '--build-number', record['build'],
                               '--version', record['version'], '--platform', 'IOS', '--include', 'betaGroups,buildBetaDetail',
                               '--paginate', '--output', 'json'], private=True))
    (destination / 'app-store-connect.json').write_text(json.dumps(response, indent=2) + '\n')
    builds = response.get('data', [])
    if len(builds) != 1 or builds[0]['attributes'].get('version') != record['build']:
        raise ValueError('App Store Connect did not return exactly the uploaded build')
    build = builds[0]
    if build['attributes'].get('processingState') != 'VALID' or build['attributes'].get('expired'):
        raise ValueError('Uploaded build is not VALID and unexpired')
    groups = build.get('relationships', {}).get('betaGroups', {}).get('data', [])
    group_ids = {g['id'] for g in groups}
    if not group_ids or not set(map(str, options.get('groupIDs', []))).issubset(group_ids):
        raise ValueError('Uploaded build lacks required TestFlight group access')
    details = [r for r in response.get('included', []) if r['type'] == 'buildBetaDetails'
               and r['id'] == build.get('relationships', {}).get('buildBetaDetail', {}).get('data', {}).get('id')]
    if not details or not any(d['attributes'].get(k) == 'IN_BETA_TESTING' for d in details
                             for k in ('internalBuildState', 'externalBuildState')):
        raise ValueError('Uploaded build is not available for beta testing')
    record['appStoreConnect'] = {'buildID': build['id'], 'processingState': 'VALID', 'groupIDs': sorted(group_ids)}
    (destination / 'release.json').write_text(json.dumps(record, indent=2) + '\n')


def assemble(project, unsigned_app, destination, sdk, native, signing, args):
    root = next(t for t in project['targets'] if t['name'] == project['rootTarget'])
    paths = bundle_paths(project)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.xtool-release-', dir=destination.parent) as temporary:
        staging = Path(temporary)
        app = staging / 'Payload' / (root['module'] + '.app')
        shutil.copytree(unsigned_app, app, symlinks=True)
        check_inventory(app, project, paths)
        toolset = json.loads((sdk / 'toolset.json').read_text())
        install_name_tool = args.install_name_tool or sdk / toolset.get('rootPath', 'toolset/bin') / 'llvm-install-name-tool'
        removed = {}
        with tempfile.TemporaryDirectory(prefix='xtool-release-resources-') as generated:
            for target in project['targets']:
                removed[target['name']] = prepare_bundle(app / paths[target['name']], target, sdk, native, Path(generated), install_name_tool)
        platform_evidence = check_platforms(app, project, paths, sdk)
        signer = args.signer or native / 'bin/xtool-sign-bundles'
        if signing is None:
            run([signer, '--adhoc', app], private=True)
            evidence = verify_adhoc(app)
        else:
            # Only generated entitlement plists are temporary; keys/configs are
            # never copied into either scratch build trees or public artifacts.
            with tempfile.TemporaryDirectory(prefix='xtool-release-signing-') as private:
                command = [signer, app, signing['certificate'], signing['privateKey']]
                for index, target in enumerate(project['targets']):
                    identity = signing['targets'][target['bundleID']]
                    entitlements = Path(private) / f'{index}.plist'
                    entitlements.write_bytes(plistlib.dumps(identity['entitlements']))
                    command += [identity['profile'], entitlements, 'sha1,sha256' if target['platform'] == 'watchos' else 'sha256']
                run(command, private=True)
            evidence = verify(app, signing['certificate'], {key: value['entitlements'] for key, value in signing['targets'].items()})
        check_inventory(app, project, paths)
        check_platforms(app, project, paths, sdk)
        verification = {'signing': 'adhoc' if signing is None else 'distribution', 'bundles': evidence,
                        'platforms': platform_evidence, 'removedHostRpathCounts': removed}
        (staging / 'verification.json').write_text(json.dumps(verification, indent=2) + '\n')
        ipa = staging / (root['module'] + '.ipa')
        with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted((staging / 'Payload').rglob('*')):
                name = str(path.relative_to(staging))
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = 0o120777 << 16
                    archive.writestr(entry, str(path.readlink()))
                else:
                    archive.write(path, name)
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        record = {'version': info['CFBundleShortVersionString'], 'build': str(project['buildNumber']),
                  'ipa': str(destination / ipa.name), 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
                  'signing': verification['signing'], 'bundles': len(evidence),
                  'architectures': {e['identifier']: e['architectures'] for e in platform_evidence}}
        (staging / 'release.json').write_text(json.dumps(record, indent=2) + '\n')
        staging.rename(destination)
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.cwd() / 'xtool-release.yml')
    parser.add_argument('--build-number', default=str(int(time.time())))
    parser.add_argument('--output', type=Path, help='Release parent directory; each build gets its own subdirectory')
    parser.add_argument('--signing', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--unsigned', action='store_true', help='Produce an ad-hoc artifact; not installable through TestFlight')
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--toolchain', type=Path, help='Explicit Swift toolchain root or bin directory')
    parser.add_argument('--xtool', default=os.environ.get('XTOOL', 'xtool'))
    parser.add_argument('--asc', default='asc')
    parser.add_argument('--signer', type=Path)
    parser.add_argument('--install-name-tool', type=Path)
    args = parser.parse_args(argv)
    if not args.build_number.isdecimal():
        parser.error('--build-number must contain decimal digits only')
    if args.unsigned and (args.upload or args.signing):
        parser.error('--unsigned cannot be combined with --upload or --signing')
    from .project import load_project
    from .workspace import discover_sdk, prepare_workspace
    project = load_project(args.config.resolve(), args.build_number)
    workspace = Path(project['root']) / '.xtool/workspace'
    wrapper = prepare_workspace(project, workspace)
    if args.prepare_only:
        print(json.dumps({'workspace': str(wrapper), 'project': str(workspace / 'project.json')}, indent=2))
        return 0
    destination = (args.output or Path(project['root']) / '.xtool/releases').resolve() / args.build_number
    if destination.exists():
        raise FileExistsError(f'Release already exists: {destination}')
    signing = None if args.unsigned else load_signing(project, args.signing)
    if args.upload and not project['release'].get('appStoreConnect', {}).get('appID'):
        raise ValueError('--upload requires appStoreConnect.appID')
    sdk = discover_sdk()
    environment = compiler_environment(project, args.toolchain)
    run([args.xtool, 'dev', 'build', '--configuration', 'release'], cwd=wrapper, env=environment)
    root = next(t for t in project['targets'] if t['name'] == project['rootTarget'])
    record = assemble(project, wrapper / 'xtool' / (root['module'] + '.app'), destination, sdk, native_home(), signing, args)
    if args.upload:
        upload_release(record, project['release']['appStoreConnect'], destination, args.asc)
    print(json.dumps(record, indent=2))
    return 0
