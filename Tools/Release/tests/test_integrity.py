"""Consumer-visible release integrity and generated-resource regressions."""
from datetime import datetime
from pathlib import Path
import hashlib
import plistlib
import struct
import tempfile
import unittest

from xtool_release.signing import validate_profile
from xtool_release.verify import macho_slices, signed_slots, verify_resources
from xtool_release.workspace import _generated_resources


class ReleaseIntegrityTests(unittest.TestCase):
    def test_universal_binary_rejects_trailing_padding(self):
        def thin(cpu):
            return struct.pack('<IIIIIIII', 0xfeedfacf, cpu, 0, 2, 0, 0, 0, 0)

        first = thin(0x200000c)
        second = thin(0x100000c)
        header = struct.pack('>II', 0xcafebabe, 2)
        header += struct.pack('>IIIII', 0x200000c, 0, 64, len(first), 5)
        header += struct.pack('>IIIII', 0x100000c, 0, 128, len(second), 6)
        binary = header.ljust(64, b'\0') + first
        binary = binary.ljust(128, b'\0') + second
        self.assertEqual([part[0] for part in macho_slices(binary)], [0x200000c, 0x100000c])
        with self.assertRaisesRegex(AssertionError, 'Trailing universal data'):
            macho_slices(binary + b'\0' * 32)

    def test_signature_allocation_slack_differs_from_indexed_blob_gaps(self):
        payload = plistlib.dumps({'get-task-allow': False})
        slot = struct.pack('>II', 0xfade7171, 8 + len(payload)) + payload

        def executable(gap):
            signature = struct.pack('>IIIII', 0xfade0cc0, 20 + gap + len(slot), 1, 5, 20 + gap)
            signature += b'\0' * gap + slot
            reserved = len(signature) + 64
            segment = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__LINKEDIT', 0, 16384, 128, reserved, 7, 1, 0, 0)
            command = struct.pack('<IIII', 0x1d, 16, 128, reserved)
            header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 0, 2, 2, 88, 0, 0)
            return (header + segment + command).ljust(128, b'\0') + signature + b'\xab' * 64

        _, _, data, commands = macho_slices(executable(0))[0]
        self.assertEqual(signed_slots(data, commands), {5: slot})
        _, _, data, commands = macho_slices(executable(1))[0]
        with self.assertRaisesRegex(AssertionError, 'Unindexed bytes inside signature SuperBlob'):
            signed_slots(data, commands)

    def test_profile_rejects_ungranted_application_group(self):
        allowed = {
            'application-identifier': 'PREFIX.com.example.*',
            'com.apple.developer.team-identifier': 'TEAM',
            'get-task-allow': False,
            'com.apple.security.application-groups': ['group.com.example.shared'],
        }
        profile = {
            'ExpirationDate': datetime(9999, 1, 1),
            'DeveloperCertificates': [b'certificate'],
            'TeamIdentifier': ['TEAM'],
            'ApplicationIdentifierPrefix': ['PREFIX'],
            'Entitlements': allowed,
        }
        requested = allowed | {'application-identifier': 'PREFIX.com.example.app'}
        self.assertEqual(validate_profile(profile, b'certificate', 'com.example.app', requested), ('TEAM', 'PREFIX'))
        requested = requested | {'com.apple.security.application-groups': ['group.com.example.ungranted']}
        with self.assertRaisesRegex(ValueError, 'does not permit entitlement com.apple.security.application-groups'):
            validate_profile(profile, b'certificate', 'com.example.app', requested)

    def test_bundle_seal_rejects_added_or_modified_resource(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'App'}))
            (bundle / '_CodeSignature').mkdir()
            resource = bundle / 'Resource.txt'
            resource.write_bytes(b'original')
            seal = {'files2': {'Resource.txt': {'hash2': hashlib.sha256(resource.read_bytes()).digest()}}}
            (bundle / '_CodeSignature/CodeResources').write_bytes(plistlib.dumps(seal))
            self.assertEqual(verify_resources(bundle), 1)
            (bundle / 'Added.txt').write_bytes(b'unsealed')
            with self.assertRaisesRegex(AssertionError, 'Unsealed bundle resource'):
                verify_resources(bundle)
            (bundle / 'Added.txt').unlink()
            resource.write_bytes(b'modified')
            with self.assertRaises(AssertionError):
                verify_resources(bundle)

    def test_generated_resource_handles_conditional_xcode_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resources = root / 'Staging/App'
            resources.mkdir(parents=True)
            (root / 'Input.txt').write_text('release notes\n')
            target = {
                'name': 'App',
                'settings': {'SRCROOT': str(root), 'CODE_SIGN_IDENTITY[sdk=iphoneos*]': 'Apple Distribution'},
                'postBuildScripts': [{
                    'name': 'Release notes',
                    'outputFiles': ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Notes.txt'],
                    'script': 'tr "[:lower:]" "[:upper:]" < "$SRCROOT/Input.txt" > "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Notes.txt"',
                }],
            }
            outputs = _generated_resources({'root': str(root)}, target, resources)
            self.assertEqual([Path(output).read_text() for output in outputs], ['RELEASE NOTES\n'])


if __name__ == '__main__':
    unittest.main()
