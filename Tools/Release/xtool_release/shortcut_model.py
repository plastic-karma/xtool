"""Serialize AppIntents phrase models from generated action metadata.

The table layout and wake-word variants were established against the same-source
Xcode 26.6 reference artifact. No reference binary is read by this generator.
"""
import ctypes
import hashlib
import json
from pathlib import Path
import struct


class FlatBuffer:
    def __init__(self):
        self.data = bytearray(4)

    def reserve(self, length, alignment=4):
        self.data.extend(b'\0' * (-len(self.data) % alignment))
        position = len(self.data)
        self.data.extend(b'\0' * length)
        return position

    def offset(self, at, target):
        if target <= at:
            raise ValueError('Expected a forward FlatBuffer reference')
        struct.pack_into('<I', self.data, at, target - at)

    def string(self, value):
        encoded = value.encode('utf-8')
        at = self.reserve(4 + len(encoded) + 1)
        struct.pack_into('<I', self.data, at, len(encoded))
        self.data[at + 4:at + 4 + len(encoded)] = encoded
        return at

    def vector(self, values, emit):
        at = self.reserve(4 + 4 * len(values))
        struct.pack_into('<I', self.data, at, len(values))
        for index, value in enumerate(values):
            self.offset(at + 4 + index * 4, emit(value))
        return at

    def table(self, fields):
        # Each field is None, a scalar (format, value), or a child emitter.
        offsets = []
        end = 4
        max_alignment = 4
        for field in fields:
            if field is None:
                offsets.append(0)
                continue
            alignment = struct.calcsize('<' + field[0]) if isinstance(field, tuple) else 4
            max_alignment = max(max_alignment, alignment)
            end += -end % alignment
            offsets.append(end)
            end += alignment
        end += -end % max_alignment
        vt = self.reserve(4 + 2 * len(fields), 2)
        struct.pack_into('<HH', self.data, vt, 4 + 2 * len(fields), end)
        for index, offset in enumerate(offsets):
            struct.pack_into('<H', self.data, vt + 4 + index * 2, offset)
        at = self.reserve(end, max_alignment)
        struct.pack_into('<i', self.data, at, at - vt)
        for offset, field in zip(offsets, fields):
            if field is None:
                continue
            if isinstance(field, tuple):
                struct.pack_into('<' + field[0], self.data, at + offset, field[1])
            else:
                self.offset(at + offset, field())
        return at


NEGATIVE_PHRASES = [
    '{app}', 'launch the {app} app', 'open the app {app}', 'close {app}',
    'quit {app}', 'exit {app}', 'uninstall {app}', 'offload {app}', 'call {app}',
    'faceTime {app}', 'call my local {app}', 'turn on notifications for {app}',
    'disable {app} notifications', 'turn off {app} Shortcuts',
    'enable Shortcuts in {app}', 'toggle {app} Shortcuts',
    'translate {app} to Portuguese', "how is {app}'s stock",
    'what is the stock price of {app}', 'read my {app} notifications',
    'new notifications from {app}', 'share {app} with Rachel', 'send {app} to Alex',
    'When was {app} founded', 'who is the CEO of {app}', 'tell me about {app}',
    'define {app}', 'driving directions to {app}', 'navigate me to {app}',
    'walk to {app}', 'news about {app}', 'read headlines about {app}',
    "go to {app}'s website", 'bring up {app}.com', 'reply saying {app}',
    "send a message to Inna saying let's meet at {app}", 'text Felix {app}',
]


def phrase_variants(phrases):
    return [prefix + phrase for phrase in phrases for prefix in ('', 'hey Siri ', 'Siri ')]


def make_model(actions, bundle_id, display_name, timestamp):
    shortcuts = actions['autoShortcuts']
    identities = []
    for index, shortcut in enumerate(shortcuts):
        phrases = [p['key'].replace('${applicationName}', display_name) for p in shortcut['phraseTemplates']]
        if any('${' in phrase for phrase in phrases):
            raise ValueError('Parameterized shortcut phrase models are not supported by this local generator')
        identities.append((shortcut['actionIdentifier'] + '_' + str(index), phrase_variants(phrases)))
    negatives = phrase_variants([p.format(app=display_name) for p in NEGATIVE_PHRASES])
    semantic = {'bundle': bundle_id, 'language': 'en', 'actions': identities, 'negativePhrases': negatives}
    identifier = hashlib.md5(json.dumps(semantic, sort_keys=True).encode()).hexdigest()
    buf = FlatBuffer()
    string = buf.string
    def phrase(text):
        return buf.table([('B', 1), lambda: buf.table([lambda: string(text)])])
    def action(item):
        name, phrases = item
        return buf.table([lambda: string(name), lambda: buf.vector([], phrase), lambda: buf.vector(phrases, phrase)])
    def bundle():
        return buf.table([lambda: string(bundle_id), lambda: buf.vector(identities, action), lambda: buf.vector(negatives, phrase)])
    def group(_):
        return buf.table([None, lambda: buf.vector([None], lambda _: bundle())])
    def metadata():
        return buf.table([lambda: string(identifier), ('Q', timestamp), lambda: buf.vector([], string), lambda: string('1.0')])
    root = buf.table([('H', 1), metadata, lambda: string('en'), lambda: buf.vector([None], group)])
    struct.pack_into('<I', buf.data, 0, root)
    return bytes(buf.data), identifier


def write_model(actions, bundle_id, display_name, timestamp, output, compression_library):
    data, identifier = make_model(actions, bundle_id, display_name, timestamp)
    lib = ctypes.CDLL(str(compression_library))
    lib.lzfse_encode_buffer.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    lib.lzfse_encode_buffer.restype = ctypes.c_size_t
    lib.lzfse_decode_buffer.argtypes = lib.lzfse_encode_buffer.argtypes
    lib.lzfse_decode_buffer.restype = ctypes.c_size_t
    buffer = ctypes.create_string_buffer(len(data) + 256)
    count = lib.lzfse_encode_buffer(buffer, len(buffer), data, len(data), None)
    if count == 0:
        raise RuntimeError('LZFSE encoding failed')
    compressed = buffer.raw[:count]
    decoded = ctypes.create_string_buffer(len(data))
    decoded_count = lib.lzfse_decode_buffer(decoded, len(decoded), compressed, count, None)
    if decoded_count != len(data) or decoded.raw != data:
        raise RuntimeError('Shortcut model compression roundtrip failed')
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'nlu.lzfse').write_bytes(compressed)
    (output / (identifier + '.version')).write_bytes(b'\0')
    return identifier
