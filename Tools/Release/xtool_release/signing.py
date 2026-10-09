"""Resolve external identities and least-privilege signing entitlements."""
from datetime import datetime, timezone
import fnmatch
import os
from pathlib import Path
import plistlib
import subprocess

import yaml


def openssl(*arguments, input=None):
    result = subprocess.run(['openssl', *map(str, arguments)], input=input,
                            capture_output=True, check=False)
    if result.returncode:
        # OpenSSL diagnostics can include private paths or input; do not relay them.
        raise ValueError('OpenSSL identity/profile verification failed')
    return result.stdout


def decode_profile(path):
    return plistlib.loads(openssl('cms', '-verify', '-inform', 'DER', '-noverify', '-in', path))


def allows(allowed, requested):
    if isinstance(requested, str):
        return isinstance(allowed, str) and fnmatch.fnmatchcase(requested, allowed)
    if isinstance(requested, list):
        return isinstance(allowed, list) and all(any(allows(a, r) for a in allowed) for r in requested)
    if isinstance(requested, dict):
        return isinstance(allowed, dict) and all(k in allowed and allows(allowed[k], v) for k, v in requested.items())
    return type(allowed) is type(requested) and allowed == requested


def validate_profile(profile, certificate, bundle_id, entitlements=None, *, development=False):
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError(f'Expired or undated provisioning profile for {bundle_id}')
    if certificate not in profile.get('DeveloperCertificates', []):
        raise ValueError(f'Provisioning profile does not include signing certificate: {bundle_id}')
    if development:
        if not profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
            raise ValueError(f'Development profile with registered devices required: {bundle_id}')
    elif 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices'):
        raise ValueError(f'App Store distribution profile required: {bundle_id}')
    allowed = profile.get('Entitlements', {})
    teams = profile.get('TeamIdentifier', [])
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if len(teams) != 1 or len(prefixes) != 1:
        raise ValueError(f'Ambiguous provisioning identity: {bundle_id}')
    application = prefixes[0] + '.' + bundle_id
    if not allows(allowed.get('application-identifier'), application):
        raise ValueError(f'Provisioning profile does not allow bundle: {bundle_id}')
    if allowed.get('get-task-allow') is not development:
        raise ValueError(f'Provisioning profile debug entitlement does not match signing mode: {bundle_id}')
    if entitlements is not None:
        if entitlements.get('application-identifier') != application:
            raise ValueError(f'Incorrect signed application identifier: {bundle_id}')
        if entitlements.get('com.apple.developer.team-identifier') != teams[0]:
            raise ValueError(f'Incorrect signed team identifier: {bundle_id}')
        if entitlements.get('get-task-allow') is not development:
            raise ValueError(f'Signed debug entitlement does not match signing mode: {bundle_id}')
        for key, value in entitlements.items():
            if key not in allowed or not allows(allowed[key], value):
                raise ValueError(f'Profile does not permit entitlement {key}: {bundle_id}')
    return teams[0], prefixes[0]


def expand_entitlements(value, team, prefix, bundle_id):
    if isinstance(value, str):
        for key, replacement in {'AppIdentifierPrefix': prefix + '.', 'TeamIdentifierPrefix': team + '.',
                                 'CFBundleIdentifier': bundle_id, 'PRODUCT_BUNDLE_IDENTIFIER': bundle_id}.items():
            value = value.replace('$(' + key + ')', replacement).replace('${' + key + '}', replacement)
        if '$(' in value or '${' in value:
            raise ValueError('Unresolved build setting in requested entitlements')
        return value
    if isinstance(value, list):
        return [expand_entitlements(v, team, prefix, bundle_id) for v in value]
    if isinstance(value, dict):
        return {k: expand_entitlements(v, team, prefix, bundle_id) for k, v in value.items()}
    return value


def load_signing(project, path=None, *, development=False):
    root = next(t for t in project['targets'] if t['name'] == project['rootTarget'])
    config_home = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
    suffix = '.development.yml' if development else '.yml'
    path = Path(path or os.environ.get('XTOOL_SIGNING_CONFIG') or
                config_home / 'xtool/signing' / (root['bundleID'] + suffix)).expanduser().resolve()
    if not path.is_file():
        raise ValueError('External signing config required; use --signing or XTOOL_SIGNING_CONFIG')
    project_root = Path(project['root']).resolve()
    if path.is_relative_to(project_root):
        raise ValueError('Signing config must remain outside the application project')
    try:
        config = yaml.safe_load(path.read_text())
    except yaml.YAMLError:
        raise ValueError('Invalid external signing configuration') from None
    if not isinstance(config, dict) or set(config) != {'certificate', 'privateKey', 'profiles'}:
        raise ValueError('Signing config requires certificate, privateKey and profiles only')
    def external(value):
        candidate = (path.parent / Path(value).expanduser()).resolve()
        if not candidate.is_file():
            raise ValueError('A configured private signing input is missing')
        if candidate.is_relative_to(project_root):
            raise ValueError('Signing material must remain outside the application project')
        return candidate
    certificate_path = external(config['certificate'])
    key_path = external(config['privateKey'])
    certificate = certificate_path.read_bytes()
    openssl('x509', '-inform', 'DER', '-in', certificate_path, '-checkend', '0', '-noout')
    start = openssl('x509', '-inform', 'DER', '-in', certificate_path, '-startdate', '-noout').decode().strip()
    not_before = datetime.strptime(start.split('=', 1)[1], '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
    if not_before > datetime.now(timezone.utc):
        raise ValueError('Signing certificate is not yet valid')
    public = openssl('x509', '-inform', 'DER', '-in', certificate_path, '-pubkey', '-noout')
    private_public = openssl('pkey', '-in', key_path, '-pubout', '-passin', 'pass:')
    if public != private_public:
        raise ValueError('Signing certificate and private key do not match')
    profiles = config['profiles']
    if not isinstance(profiles, dict):
        raise ValueError('Signing profiles must map bundle identifiers to external profile paths')
    targets = {}
    for target in project['targets']:
        bundle_id = target['bundleID']
        if bundle_id not in profiles:
            raise ValueError(f'Missing provisioning profile for {bundle_id}')
        profile_path = external(profiles[bundle_id])
        profile = decode_profile(profile_path)
        team, prefix = validate_profile(profile, certificate, bundle_id, development=development)
        requested = expand_entitlements(target['entitlements'], team, prefix, bundle_id)
        required = {'application-identifier': prefix + '.' + bundle_id,
                    'com.apple.developer.team-identifier': team, 'get-task-allow': development}
        for key, value in required.items():
            if key in requested and requested[key] != value:
                raise ValueError(f'Conflicting requested entitlement {key}: {bundle_id}')
            requested[key] = value
        if profile['Entitlements'].get('beta-reports-active') is True:
            requested.setdefault('beta-reports-active', True)
        validate_profile(profile, certificate, bundle_id, requested, development=development)
        targets[bundle_id] = {'profile': profile_path, 'entitlements': requested}
    return {'certificate': certificate_path, 'privateKey': key_path, 'targets': targets}
