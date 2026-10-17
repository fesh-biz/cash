"""Відбиток (SHA-256) сертифіката, яким підписано APK.

Читає APK Signing Block (схеми v2/v3) без Android SDK:
    python3 scripts/apk_cert.py Cash.apk

Два APK встановлюються один поверх одного, лише якщо відбитки однакові.
"""

import hashlib
import struct
import sys

V2 = 0x7109871A
V3 = 0xF05368C0


def _u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def _seq(b):
    """Послідовність елементів із 4-байтовою довжиною перед кожним."""
    off = 0
    while off + 4 <= len(b):
        n = _u32(b, off)
        yield b[off + 4:off + 4 + n]
        off += 4 + n


def _lp(b, off=0):
    n = _u32(b, off)
    return b[off + 4:off + 4 + n], off + 4 + n


def certs(path):
    data = open(path, 'rb').read()
    eocd = data.rfind(b'PK\x05\x06')
    if eocd < 0:
        raise ValueError('не zip-файл')
    cd = _u32(data, eocd + 16)
    if data[cd - 16:cd] != b'APK Sig Block 42':
        raise ValueError('немає підпису v2/v3')
    size = struct.unpack_from('<Q', data, cd - 24)[0]
    start = cd - size - 8
    off = start + 8
    blocks = {}
    while off < cd - 24:
        n = struct.unpack_from('<Q', data, off)[0]
        bid = _u32(data, off + 8)
        blocks[bid] = data[off + 12:off + 8 + n]
        off += 8 + n
    result = []
    for bid in (V3, V2):
        if bid not in blocks:
            continue
        signers, _ = _lp(blocks[bid])
        for signer in _seq(signers):
            signed, _ = _lp(signer)
            _, o = _lp(signed)          # digests
            cert_seq, _ = _lp(signed, o)
            for der in _seq(cert_seq):
                result.append(hashlib.sha256(der).hexdigest().upper())
        if result:
            break
    if not result:
        raise ValueError('сертифікат не знайдено')
    return result


def fmt(h):
    return ':'.join(h[i:i + 2] for i in range(0, len(h), 2))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        try:
            print(p, fmt(certs(p)[0]))
        except Exception as e:
            print(p, 'помилка:', e)
            sys.exit(1)
