"""Prepare an isolated SwiftPM wrapper without modifying application sources."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess

import yaml

from .project import ProjectError, expand


def discover_sdk() -> Path:
    """Use the same SDK selection as DarwinSDK.current in the xtool builder."""
    config = os.environ.get('XDG_CONFIG_HOME')
    if config and not Path(config).is_absolute():
        raise ProjectError('XDG_CONFIG_HOME must be an absolute path')
    swiftpm = Path(config) / 'swiftpm' if config else Path.home() / '.swiftpm'
    path = (swiftpm / 'swift-sdks/darwin.artifactbundle').resolve()
    if not (path / 'Xcode.app/Contents/Developer/Platforms').is_dir():
        raise ProjectError(f'No normal Darwin SDK at {path}; run xtool sdk install')
    return path


def _sdk_versions(sdk, platforms):
    versions = {}
    for platform in platforms:
        apple = {'ios': 'iPhoneOS', 'watchos': 'WatchOS'}[platform]
        directory = sdk / f'Xcode.app/Contents/Developer/Platforms/{apple}.platform/Developer/SDKs'
        candidates = sorted({path.resolve() for path in directory.glob('*.sdk')})
        if len(candidates) != 1:
            raise ProjectError(f'Expected one installed {apple} SDK under {directory}')
        settings_path = candidates[0] / 'SDKSettings.json'
        if settings_path.is_file():
            settings = json.loads(settings_path.read_text())
        else:
            with (candidates[0] / 'SDKSettings.plist').open('rb') as stream:
                settings = plistlib.load(stream)
        version = str(settings.get('Version', ''))
        if not version:
            raise ProjectError(f'SDK does not declare its version: {candidates[0]}')
        versions[platform] = version
    return versions


def _quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def _strings(values):
    return '[' + ', '.join(_quote(value) for value in values) + ']'


def _package(name, package):
    if 'path' in package:
        return f'.package(name: {_quote(name)}, path: {_quote(package["path"])})'
    url = package.get('url')
    if not url:
        raise ProjectError(f'Package {name} has neither a path nor a URL')
    choices = [('from', 'from'), ('version', 'from'), ('exactVersion', 'exact'), ('branch', 'branch'), ('revision', 'revision')]
    requirement = next((f'{swift}: {_quote(package[key])}' for key, swift in choices if key in package), None)
    if 'minorVersion' in package:
        requirement = f'.upToNextMinor(from: {_quote(package["minorVersion"])})'
    if 'majorVersion' in package:
        requirement = f'.upToNextMajor(from: {_quote(package["majorVersion"])})'
    if not requirement:
        raise ProjectError(f'Package {name} has an unsupported version requirement: {package}')
    return f'.package(name: {_quote(name)}, url: {_quote(url)}, {requirement})'


def _swift_flags(target, sdk_version):
    settings = target['settings']
    flags = ['-Xfrontend', '-enable-cross-import-overlays', '-Xfrontend', '-target-sdk-version', '-Xfrontend', sdk_version,
             '-Xfrontend', '-disable-autolink-framework', '-Xfrontend', 'SwiftUICore']
    if target['kind'] == 'extension':
        flags.append('-application-extension')
    if settings.get('SWIFT_VERSION'):
        flags += ['-swift-version', str(settings['SWIFT_VERSION']).split('.')[0]]
    if settings.get('SWIFT_DEFAULT_ACTOR_ISOLATION'):
        flags += ['-default-isolation', str(settings['SWIFT_DEFAULT_ACTOR_ISOLATION'])]
    if str(settings.get('SWIFT_APPROACHABLE_CONCURRENCY', '')).upper() == 'YES':
        for feature in ('NonisolatedNonsendingByDefault', 'InferIsolatedConformances', 'InferSendableFromCaptures', 'DisableOutwardActorInference', 'GlobalActorIsolatedTypesUsability'):
            flags += ['-enable-upcoming-feature', feature]
    if str(settings.get('SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY', '')).upper() == 'YES':
        flags += ['-enable-upcoming-feature', 'MemberImportVisibility']
    if settings.get('SWIFT_STRICT_CONCURRENCY'):
        flags += ['-strict-concurrency=' + str(settings['SWIFT_STRICT_CONCURRENCY'])]
    for key in ('SWIFT_OBJC_BRIDGING_HEADER', 'SWIFT_OBJC_INTERFACE_HEADER_NAME', 'SWIFT_INCLUDE_PATHS', 'FRAMEWORK_SEARCH_PATHS', 'HEADER_SEARCH_PATHS', 'LIBRARY_SEARCH_PATHS'):
        if settings.get(key):
            raise ProjectError(f'Unsupported compiler/search-path setting in {target["name"]}: {key}')
    for key, prefix in (('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '-D'), ('OTHER_SWIFT_FLAGS', None)):
        value = expand(settings.get(key, []), settings)
        values = shlex.split(value) if isinstance(value, str) else value
        for value in values:
            flags += [prefix, str(value)] if prefix else [str(value)]
    return flags


def _generated_resources(project, target, directory):
    outputs = []
    settings = target['settings'] | {'TARGET_BUILD_DIR': str(directory.parent), 'BUILT_PRODUCTS_DIR': str(directory.parent),
                                    'UNLOCALIZED_RESOURCES_FOLDER_PATH': directory.name, 'CONTENTS_FOLDER_PATH': directory.name}
    environment = os.environ.copy()
    for key, value in settings.items():
        if '=' not in key and isinstance(value, (str, int, float)) and '$(' not in str(value) and '${' not in str(value):
            environment[key] = str(value)
    for script in target.get('postBuildScripts', []):
        if not script.get('outputFiles'):
            raise ProjectError(f'Build script needs declared resource outputs: {script.get("name", target["name"])}')
        paths = [Path(expand(value, settings)).resolve() for value in script['outputFiles']]
        for path in paths:
            if not path.is_relative_to(directory):
                raise ProjectError(f'Build script output must be a staged bundle resource: {path}')
            path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([script.get('shell', '/bin/sh'), '-eu', '-c', script['script']], cwd=project['root'], env=environment, check=True)
        for path in paths:
            if not path.exists():
                raise ProjectError(f'Build script did not produce its declared resource: {path}')
            outputs.append(str(path))
    return outputs


def prepare_workspace(project: dict, workspace: Path) -> Path:
    """Return the generated wrapper directory; credentials are never needed here."""
    platform_minimums = {}
    for target in project['targets']:
        version = target['minimumOS']
        old = platform_minimums.setdefault(target['platform'], version)
        normalized = lambda value: tuple((str(value).split('.') + ['0', '0'])[:3])
        if normalized(old) != normalized(version):
            raise ProjectError(
                f'Mixed deployment targets on {target["platform"]} are not representable in one Swift package: '
                f'{old} and {version} ({target["name"]}); refusing to change a product deployment target'
            )
    workspace = Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    wrapper = workspace / 'app'
    marker = wrapper / '.xtool-release-workspace'
    if wrapper.exists():
        if not marker.is_file():
            raise ProjectError(f'Refusing to replace a directory not created by xtool release: {wrapper}')
        # Only the generated trees are replaced; SwiftPM build caches stay reusable.
        for name in ('Sources', 'Resources'):
            if (wrapper / name).exists():
                shutil.rmtree(wrapper / name)
    wrapper.mkdir(exist_ok=True)
    marker.write_text('Generated by xtool release\n')
    versions = _sdk_versions(discover_sdk(), {target['platform'] for target in project['targets']})
    products = []
    manifest_targets = []
    configurations = {}
    for target in project['targets']:
        module = target['module']
        sources = wrapper / 'Sources' / module
        resources = wrapper / 'Resources' / module
        sources.mkdir(parents=True)
        resources.mkdir(parents=True)
        names = set()
        for source in target['sources']:
            path = Path(source)
            if path.name in names:
                raise ProjectError(f'Duplicate Swift source basename in {module}: {path.name}')
            names.add(path.name)
            (sources / path.name).symlink_to(path)
        info_path = resources / 'Info.plist'
        info_path.write_bytes(plistlib.dumps(target['info']))
        entitlements_path = resources / 'Entitlements.plist'
        entitlements_path.write_bytes(plistlib.dumps(target['entitlements']))
        resource_paths = list(target['resources']) + _generated_resources(project, target, resources)
        resource_names = set()
        for resource in resource_paths:
            name = Path(resource).name
            if name in resource_names or name in ('Info.plist', 'Entitlements.plist'):
                raise ProjectError(f'Conflicting bundle resource basename in {module}: {name}')
            resource_names.add(name)
        config = {'product': module, 'bundleID': target['bundleID'], 'infoPath': str(info_path), 'entitlementsPath': str(entitlements_path)}
        if resource_paths:
            config['resources'] = resource_paths
        configurations[target['name']] = config
        dependencies = []
        for dependency in target['packageDependencies']:
            if dependency['package'] not in project['packages']:
                raise ProjectError(f'Unknown Swift package: {dependency["package"]}')
            dependencies.append(f'.product(name: {_quote(dependency["product"])}, package: {_quote(dependency["package"])})')
        flags = _swift_flags(target, versions[target['platform']])
        link_flags = ['-Xlinker', '-no_implicit_dylibs']
        other_link_flags = expand(target['settings'].get('OTHER_LDFLAGS', []), target['settings'])
        link_flags += shlex.split(other_link_flags) if isinstance(other_link_flags, str) else other_link_flags
        linker = [f'.unsafeFlags({_strings(link_flags)})']
        linker += [f'.linkedFramework({_quote(framework)})' for framework in target['frameworks']]
        manifest_targets.append('        .target(\n' + f'            name: {_quote(module)},\n' + f'            dependencies: [{", ".join(dependencies)}],\n' + f'            swiftSettings: [.unsafeFlags({_strings(flags)})],\n' + f'            linkerSettings: [{", ".join(linker)}]\n' + '        )')
        products.append(f'        .library(name: {_quote(module)}, targets: [{_quote(module)}])')
    for target in project['targets']:
        if target['parent'] is None:
            continue
        parent_target = next(item for item in project['targets'] if item['name'] == target['parent'])
        parent = configurations[target['parent']]
        if target['kind'] == 'extension' and parent_target['platform'] == target['platform']:
            parent.setdefault('extensions', []).append(configurations[target['name']])
        elif target['kind'] == 'application' and target['platform'] == 'watchos' and parent_target['platform'] == 'ios':
            if 'watchApp' in parent:
                raise ProjectError('Only one embedded watch application is supported')
            parent['watchApp'] = configurations[target['name']]
        else:
            raise ProjectError(f'Unsupported embedding relation: {target["parent"]} -> {target["name"]}')
    platform_specs = [f'.{dict(ios="iOS", watchos="watchOS")[platform]}({_quote(version)})' for platform, version in sorted(platform_minimums.items())]
    manifest = '// swift-tools-version: 6.2\nimport PackageDescription\n\nlet package = Package(\n'
    manifest += f'    name: {_quote(project["name"] + "Release")},\n    platforms: [{", ".join(platform_specs)}],\n'
    manifest += '    products: [\n' + ',\n'.join(products) + '\n    ],\n'
    manifest += '    dependencies: [' + ', '.join(_package(name, package) for name, package in project['packages'].items()) + '],\n'
    manifest += '    targets: [\n' + ',\n'.join(manifest_targets) + '\n    ]\n)\n'
    (wrapper / 'Package.swift').write_text(manifest)
    config = {'version': 1, 'skipLSP': True, **configurations[project['rootTarget']]}
    (wrapper / 'xtool.yml').write_text(yaml.safe_dump(config, sort_keys=False))
    (workspace / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
    return wrapper
