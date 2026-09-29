#!/usr/bin/env python3
"""Verify all code pages, signed special slots, CMS signatures and bundle seals."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
from .signing import decode_profile, validate_profile

# Security checks below must never disappear under python -O.
if not __debug__:
    raise RuntimeError('Release verification requires Python assertions enabled')


def macho_slices(data):
    magic = struct.unpack_from('>I', data)[0]
    if magic == 0xcafebabe:
        count = struct.unpack_from('>I', data, 4)[0]
        result = []
        cursor = 8 + count * 20
        assert count and cursor <= len(data), 'Invalid universal Mach-O header'
        entries = [struct.unpack_from('>IIIII', data, 8 + index * 20) for index in range(count)]
        assert len({(c, s) for c, s, _, _, _ in entries}) == count, 'Duplicate universal architecture'
        for index, (cpu, subtype, offset, size, alignment) in enumerate(sorted(entries, key=lambda entry: entry[2])):
            assert alignment < 32 and offset % (1 << alignment) == 0
            assert cursor <= offset and offset + size <= len(data), 'Invalid universal Mach-O slice'
            assert offset - cursor < (1 << alignment), 'Excess universal slice padding'
            assert not any(data[cursor:offset]), 'Nonzero universal slice padding'
            slices = macho_slices(data[offset:offset + size])
            assert [(c, s) for c, s, _, _ in slices] == [(cpu, subtype)], 'Universal architecture mismatch'
            result.extend(slices)
            cursor = offset + size
        assert cursor == len(data), ('Trailing universal data', len(data) - cursor)
        return result
    magic, cpu, subtype, kind, count, commands_size, flags = struct.unpack_from('<IIIIIII', data)
    if magic not in (0xfeedface, 0xfeedfacf):
        raise ValueError('Unsupported Mach-O header')
    cursor = 32 if magic == 0xfeedfacf else 28
    commands_end = cursor + commands_size
    assert commands_end <= len(data), 'Truncated Mach-O commands'
    commands = []
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor + size > commands_end:
            raise ValueError('Invalid Mach-O load command')
        commands.append((command, data[cursor:cursor + size]))
        cursor += size
    assert cursor == commands_end, 'Mach-O command extent mismatch'
    return [(cpu, subtype, data, commands)]


def signed_slots(data, commands):
    signatures = [body for kind, body in commands if kind == 0x1d]
    assert len(signatures) == 1, 'Expected exactly one code signature'
    command = signatures[0]
    offset, length = struct.unpack_from('<II', command, 8)
    assert offset + length == len(data), ('signature extent', offset, length, len(data))
    cpu = struct.unpack_from('<I', data, 4)[0]
    linkedit_count = 0
    for kind, body in commands:
        if kind in (1, 0x19) and body[8:24].split(b'\0', 1)[0] == b'__LINKEDIT':
            linkedit_count += 1
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<IIII' if kind == 1 else '<QQQQ', body, 24)
            page = 16384 if cpu in (0x100000c, 0x200000c) else 4096
            assert vmsize % page == 0 and vmsize >= filesize, ('linkedit virtual extent', vmsize, filesize, page)
            assert fileoff <= offset and fileoff + filesize == len(data), ('linkedit file extent', fileoff, filesize)
    assert linkedit_count == 1, 'Expected exactly one __LINKEDIT segment'
    blob = data[offset:offset + length]
    magic, size, count = struct.unpack_from('>III', blob)
    assert magic == 0xfade0cc0 and size <= len(blob)
    assert 12 + count * 8 <= size, 'Invalid signature slot index'
    # LC_CODE_SIGNATURE can reserve more bytes than SuperBlob.length. Apple
    # validates the indexed extent, not unused reservation bytes after it.
    extents = []
    result = {}
    for index in range(count):
        kind, start = struct.unpack_from('>II', blob, 12 + index * 8)
        blob_magic, blob_size = struct.unpack_from('>II', blob, start)
        assert blob_size >= 8 and start >= 12 + count * 8 and start + blob_size <= size
        assert kind not in result, 'Duplicate signature slot'
        assert all(start + blob_size <= a or start >= b for a, b in extents), 'Overlapping signature slots'
        extents.append((start, start + blob_size))
        result[kind] = blob[start:start + blob_size]
    cursor = 12 + count * 8
    for start, end in sorted(extents):
        assert start == cursor, 'Unindexed bytes inside signature SuperBlob'
        cursor = end
    assert cursor == size, 'Unindexed trailing bytes inside signature SuperBlob'
    return result


def der_items(data):
    # Apple's CMS also uses BER indefinite-length constructed containers.
    def item(offset):
        tag, length = data[offset:offset + 2]
        offset += 2
        if length == 128:
            assert tag & 32
            start = offset
            while data[offset:offset + 2] != b'\0\0':
                _, _, offset = item(offset)
            return tag, data[start:offset], offset + 2
        if length & 128:
            count = length & 127
            assert offset + count <= len(data)
            length = int.from_bytes(data[offset:offset + count], 'big')
            offset += count
        assert offset + length <= len(data)
        return tag, data[offset:offset + length], offset + length
    items, offset = [], 0
    while offset < len(data):
        tag, value, offset = item(offset)
        items.append((tag, value))
    return items


def verify_agility(cms, directories):
    content = der_items(der_items(cms)[0][1])
    signed_data = der_items(der_items(content[1][1])[0][1])
    signers = der_items(signed_data[-1][1])
    assert len(signers) == 1
    signer = der_items(signers[0][1])
    attributes = der_items(next(value for tag, value in signer if tag == 0xa0))
    attributes = {der_items(value)[0][1].hex(): der_items(der_items(value)[1][1])
                  for tag, value in attributes}
    encoded_plist = attributes['2a864886f763640901'][0][1]
    plist_format = plistlib.FMT_BINARY if encoded_plist.startswith(b'bplist00') else plistlib.FMT_XML
    plist_hashes = plistlib.loads(encoded_plist, fmt=plist_format)['cdhashes']
    assert plist_hashes == [digest[:20] for algorithm, pages, digest in directories]
    algorithms = {'sha1': '2b0e03021a', 'sha256': '608648016503040201'}
    expected = {algorithms[algorithm]: digest for algorithm, pages, digest in directories}
    values = attributes['2a864886f763640902']
    assert len(values) == len(expected), ('CMS V2 digest count', len(values), len(expected))
    actual = {}
    for tag, value in values:
        assert tag == 0x30
        fields = der_items(value)
        assert [tag for tag, value in fields] == [6, 4]
        actual[fields[0][1].hex()] = fields[1][1]
    assert actual == expected, ('CMS V2 digests', actual, expected)


def verify_directory(directory, bundle, executable, cpu, data, commands, slots, adhoc=False):
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        magic, length, version, flags, hash_offset, identifier_offset, special_count, code_count, code_limit = struct.unpack_from('>IIIIIIIII', directory)
        assert magic == 0xfade0c02 and length == len(directory)
        assert bool(flags & 2) == adhoc, (executable, cpu, 'incorrect signature identity mode')
        if version >= 0x20400:
            executable_base, executable_limit, executable_flags = struct.unpack_from('>QQQ', directory, 64)
            text_segments = []
            for kind, body in commands:
                if kind in (1, 0x19) and body[8:24].split(b'\0', 1)[0] == b'__TEXT':
                    vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<IIII' if kind == 1 else '<QQQQ', body, 24)
                    text_segments.append((fileoff, vmsize))
            assert text_segments == [(executable_base, executable_limit)], (
                executable, hex(cpu), 'executable segment bounds', text_segments,
                (executable_base, executable_limit))
            assert executable_flags & 1, (executable, cpu, 'missing executable signature flag')
        hash_size, hash_type, platform, page_exponent = struct.unpack_from('BBBB', directory, 36)
        algorithms = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}
        algorithm = algorithms[hash_type]
        assert hash_size == {1: 20, 2: 32, 3: 20, 4: 48}[hash_type], 'Invalid CodeDirectory hash size'
        assert 0 < page_exponent <= 16, 'Unsupported code page size'
        signature_offset = struct.unpack_from('<I', next(body for kind, body in commands if kind == 0x1d), 8)[0]
        assert code_limit == signature_offset, 'Unsigned executable bytes'
        assert hash_offset - special_count * hash_size >= 44, 'Invalid special-slot extent'
        assert hash_offset + code_count * hash_size <= length, 'Invalid code-slot extent'
        def digest(value):
            return hashlib.new(algorithm, value).digest()[:hash_size]
        page_size = 1 << page_exponent
        assert code_count == (code_limit + page_size - 1) // page_size
        for page in range(code_count):
            start = page * page_size
            actual = digest(data[start:min(start + page_size, code_limit)])
            expected = directory[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size]
            assert actual == expected, (executable, cpu, 'code page', page)
        special = {1: (bundle / 'Info.plist').read_bytes(),
                   3: (bundle / '_CodeSignature/CodeResources').read_bytes()}
        for kind in (2, 5, 7):
            if not adhoc or kind in slots:
                special[kind] = slots[kind]
        for kind, value in special.items():
            assert kind <= special_count
            expected = directory[hash_offset - kind * hash_size:hash_offset - (kind - 1) * hash_size]
            assert digest(value) == expected, (executable, cpu, 'special slot', kind)
        assert directory[identifier_offset:].split(b'\0', 1)[0].decode() == info['CFBundleIdentifier']
        return algorithm, code_count, hashlib.new(algorithm, directory).digest()


def verify_code(bundle, executable, certificate, profile, expected_entitlements=None):
    evidence = []
    for cpu, subtype, data, commands in macho_slices(executable.read_bytes()):
        slots = signed_slots(data, commands)
        directories = [blob for kind, blob in sorted(slots.items()) if kind == 0 or 0x1000 <= kind < 0x1005]
        verified = [verify_directory(directory, bundle, executable, cpu, data, commands, slots)
                    for directory in directories]
        entitlements = plistlib.loads(slots[5][8:])
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        validate_profile(profile, certificate.read_bytes(), info['CFBundleIdentifier'], entitlements)
        if expected_entitlements is not None:
            assert entitlements == expected_entitlements, 'Signed entitlements differ from requested entitlements'
        expected_digests = ['sha1', 'sha256'] if info['CFBundleSupportedPlatforms'] == ['WatchOS'] else ['sha256']
        assert [v[0] for v in verified] == expected_digests, 'Incorrect platform signature digest policy'
        with tempfile.TemporaryDirectory(prefix='xtool-signature-verify-') as temporary:
            temp = Path(temporary)
            (temp / 'directory').write_bytes(slots[0])
            (temp / 'cms').write_bytes(slots[0x10000][8:])
            subprocess.run(['openssl', 'cms', '-verify', '-binary', '-noverify', '-inform', 'DER',
                            '-in', str(temp / 'cms'), '-content', str(temp / 'directory'),
                            '-out', str(temp / 'verified'), '-signer', str(temp / 'signer.pem')],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            signer = subprocess.run(['openssl', 'x509', '-in', str(temp / 'signer.pem'), '-outform', 'DER'],
                                    check=True, capture_output=True).stdout
            assert signer == certificate.read_bytes(), (executable, 'unexpected signing certificate')
        verify_agility(slots[0x10000][8:], verified)
        platform_records = []
        for kind, body in commands:
            if kind == 0x32:
                platform_id, minimum, sdk, tools = struct.unpack_from('<IIII', body, 8)
                platform_records.append({'platform': platform_id, 'minimum': minimum, 'sdk': sdk})
            if kind in (0xc, 0x80000018, 0x8000001c):
                start = struct.unpack_from('<I', body, 8)[0]
                value = body[start:].split(b'\0', 1)[0].decode()
                assert not value.startswith('/') or value.startswith(('/System/Library/', '/usr/lib/')), (executable, 'host load path', value)
                assert 'SwiftUICore.framework' not in value, (executable, 'private framework autolink', value)
        evidence.append({'cpu': hex(cpu), 'subtype': subtype, 'codePages': verified[0][1],
                         'signatures': [v[0] for v in verified], 'platformRecords': platform_records})
    return evidence


def verify_resources(bundle):
    resources = plistlib.loads((bundle / '_CodeSignature/CodeResources').read_bytes())
    checked = 0
    for table in ('files', 'files2'):
        for name, record in resources.get(table, {}).items():
            path = bundle / name
            assert not Path(name).is_absolute() and '..' not in Path(name).parts, 'Unsafe resource seal path'
            if isinstance(record, bytes):
                assert hashlib.sha1(path.read_bytes()).digest() == record, path
            elif 'symlink' in record:
                assert str(path.readlink()) == record['symlink'], path
            else:
                assert 'hash' in record or 'hash2' in record, ('Unsupported resource seal', name)
                if 'hash2' in record:
                    assert hashlib.sha256(path.read_bytes()).digest() == record['hash2'], path
                if 'hash' in record:
                    assert hashlib.sha1(path.read_bytes()).digest() == record['hash'], path
            checked += 1
    # No newly added resource may escape the seal. Nested bundle contents are
    # validated independently and may also appear in the parent's seal.
    seals = resources.get('files2', {})
    executable = plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleExecutable']
    for path in bundle.rglob('*'):
        if not path.is_file() and not path.is_symlink():
            continue
        relative = path.relative_to(bundle)
        if any(p.suffix in ('.app', '.appex') for p in relative.parents if p != Path('.')):
            continue
        if relative.parts[0] == '_CodeSignature' or str(relative) in ('Info.plist', executable):
            continue
        assert str(relative) in seals, ('Unsealed bundle resource', str(relative))
    return checked


def verify(app, certificate, expected_entitlements=None):
    bundles = [app] + sorted(app.rglob('*.app')) + sorted(app.rglob('*.appex'))
    report = []
    verified_executables = set()
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        profile = decode_profile(bundle / 'embedded.mobileprovision')
        validate_profile(profile, certificate.read_bytes(), info['CFBundleIdentifier'])
        requested = None if expected_entitlements is None else expected_entitlements[info['CFBundleIdentifier']]
        report.append({'bundle': str(bundle.relative_to(app.parent)), 'identifier': info['CFBundleIdentifier'],
                       'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                       'slices': verify_code(bundle, bundle / info['CFBundleExecutable'], certificate, profile, requested),
                       'sealedResources': verify_resources(bundle), 'profile': profile['UUID']})
        verified_executables.add(bundle / info['CFBundleExecutable'])
    verify_executable_inventory(app, verified_executables)
    return report


def verify_executable_inventory(app, verified_executables):
    for path in app.rglob('*'):
        if path.is_symlink():
            assert path.resolve().is_relative_to(app.resolve()), ('Escaping bundle symlink', path)
        if path.is_file():
            with path.open('rb') as file:
                magic = file.read(4)
            if magic in (b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
                         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                assert path in verified_executables, ('Unverified embedded Mach-O', path)


def verify_adhoc(app):
    """Verify smoke artifacts without claiming certificate/profile validation."""
    report = []
    verified_executables = set()
    for bundle in [app] + sorted(app.rglob('*.app')) + sorted(app.rglob('*.appex')):
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        executable = bundle / info['CFBundleExecutable']
        evidence = []
        assert not (bundle / 'embedded.mobileprovision').exists(), 'Unexpected profile in ad-hoc artifact'
        for cpu, subtype, data, commands in macho_slices(executable.read_bytes()):
            slots = signed_slots(data, commands)
            assert slots.get(0x10000, b'') in (b'', bytes.fromhex('fade0b0100000008')), 'Unexpected CMS signature in ad-hoc artifact'
            directories = [blob for kind, blob in sorted(slots.items()) if kind == 0 or 0x1000 <= kind < 0x1005]
            verified = [verify_directory(d, bundle, executable, cpu, data, commands, slots, adhoc=True) for d in directories]
            assert [v[0] for v in verified] == ['sha256'], 'Ad-hoc artifacts require SHA256'
            evidence.append({'cpu': hex(cpu), 'subtype': subtype, 'codePages': verified[0][1], 'signatures': ['sha256']})
        report.append({'bundle': str(bundle.relative_to(app.parent)), 'identifier': info['CFBundleIdentifier'],
                       'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                       'slices': evidence, 'sealedResources': verify_resources(bundle)})
        verified_executables.add(executable)
    verify_executable_inventory(app, verified_executables)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--certificate', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.app, args.certificate), indent=2))
