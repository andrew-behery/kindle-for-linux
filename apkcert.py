#!/usr/bin/env python3
"""Print the SHA-256 of the certificate(s) an APK is signed with, from its APK Signing Block.

    apkcert.py some.apk            ->  <sha256 hex>  <scheme>   (one line per signer)
    apkcert.py some.apk --expect X ->  exit 0 if every signer's certificate is X, else 1

Android checks at install time that the APK's signatures are valid for the certificate
embedded in it, so pinning that certificate is enough to know who signed the file, wherever it
was downloaded from. Supports signature schemes v2 and v3 (every current Play app has one).
Standard library only.
"""
import hashlib
import struct
import sys

BLOCK_IDS = {0x1B93AD61: "v3.1", 0xF05368C0: "v3", 0x7109871A: "v2"}
MAGIC = b"APK Sig Block 42"


def lp(buf, off):
    """A uint32-little-endian length-prefixed field: returns (bytes, offset after it)."""
    (n,) = struct.unpack_from("<I", buf, off)
    start = off + 4
    if start + n > len(buf):
        raise ValueError("truncated field")
    return buf[start : start + n], start + n


def lp_items(buf):
    off = 0
    while off < len(buf):
        item, off = lp(buf, off)
        yield item


def signing_blocks(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        tail_len = min(size, 65536 + 22)
        f.seek(size - tail_len)
        tail = f.read()
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise ValueError("not a zip/APK")
        (cd_offset,) = struct.unpack_from("<I", tail, eocd + 16)
        f.seek(cd_offset - 24)
        footer = f.read(24)
        if footer[8:] != MAGIC:
            raise ValueError("no APK Signing Block (only v1/JAR signing?)")
        (block_size,) = struct.unpack_from("<Q", footer, 0)
        f.seek(cd_offset - block_size - 8)
        block = f.read(block_size + 8)
    pairs = block[8:-24]
    off = 0
    while off < len(pairs):
        (n,) = struct.unpack_from("<Q", pairs, off)
        (bid,) = struct.unpack_from("<I", pairs, off + 8)
        yield bid, pairs[off + 12 : off + 8 + n]
        off += 8 + n


def signer_certs(path):
    """[(sha256 of first certificate, scheme)] for the newest scheme present."""
    blocks = dict(signing_blocks(path))
    for bid, scheme in BLOCK_IDS.items():
        if bid not in blocks:
            continue
        signers, _ = lp(blocks[bid], 0)
        out = []
        for signer in lp_items(signers):
            signed_data, _ = lp(signer, 0)
            _digests, off = lp(signed_data, 0)
            certs, _ = lp(signed_data, off)
            first_cert = next(lp_items(certs))
            out.append((hashlib.sha256(first_cert).hexdigest(), scheme))
        return out
    raise ValueError("no v2/v3 signature block")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    try:
        certs = signer_certs(sys.argv[1])
    except (OSError, ValueError, struct.error, StopIteration) as e:
        print(f"apkcert: {e}", file=sys.stderr)
        sys.exit(2)
    if len(sys.argv) == 4 and sys.argv[2] == "--expect":
        sys.exit(0 if certs and all(c == sys.argv[3].lower() for c, _ in certs) else 1)
    for cert, scheme in certs:
        print(cert, scheme)


if __name__ == "__main__":
    main()
