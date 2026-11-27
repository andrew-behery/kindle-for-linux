#!/usr/bin/env python3
"""Print the SHA-256 of the certificate(s) an APK is signed with, from its APK Signing Block.

    apkcert.py some.apk            ->  <sha256 hex>  <scheme>   (one line per signer)
    apkcert.py some.apk --expect X ->  exit 0 if every signer's certificate is X, else 1
    apkcert.py some.apk --kindle X ->  also exit 3 for Amazon's Fire tablet build (it can't be
                                       installed on ordinary Android) and 4 without arm64 code

Android checks at install time that the APK's signatures are valid for the certificate
embedded in it, so pinning that certificate is enough to know who signed the file, wherever it
was downloaded from. Supports signature schemes v2 and v3 (every current Play app has one).
Standard library only.
"""
import hashlib
import struct
import sys
import zipfile

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
        if cd_offset == 0xFFFFFFFF:
            raise ValueError("ZIP64 APK not supported")
        if cd_offset < 32 or cd_offset > size:
            raise ValueError("corrupt ZIP central directory offset")
        f.seek(cd_offset - 24)
        footer = f.read(24)
        if footer[8:] != MAGIC:
            raise ValueError("no APK Signing Block (only v1/JAR signing?)")
        (block_size,) = struct.unpack_from("<Q", footer, 0)
        if block_size < 24 or block_size > 64 * 1024 * 1024 or block_size + 8 > cd_offset:
            raise ValueError("invalid APK Signing Block size")
        f.seek(cd_offset - block_size - 8)
        block = f.read(block_size + 8)
    pairs = block[8:-24]
    off = 0
    while off + 12 <= len(pairs):
        (n,) = struct.unpack_from("<Q", pairs, off)
        if n < 4 or off + 8 + n > len(pairs):
            raise ValueError("truncated APK Signing Block entry")
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


def kindle_build_problem(path):
    """None if this is the Kindle build for ordinary Android (Google Play's), else a reason.

    Amazon's Fire tablet build (14.x, what APKPure and the Amazon Appstore carry) defines the
    permission ACCESS_ALL_DOWNLOADS, which Android's download service owns, so ordinary Android
    refuses to install it; it also starts at TabletStartActivity. Neither name appears in the
    Play build. The Play build has arm64 code; the Fire one only 32-bit ARM.
    """
    with zipfile.ZipFile(path) as z:
        manifest = z.read("AndroidManifest.xml")  # binary XML: its strings are UTF-16 or UTF-8
        names = z.namelist()
    fire_marks = ("android.permission.ACCESS_ALL_DOWNLOADS", "com.amazon.kindle.TabletStartActivity")
    if any(m.encode() in manifest or m.encode("utf-16-le") in manifest for m in fire_marks):
        return 3, "this is Amazon's Fire tablet build of Kindle, which ordinary Android can't install"
    if not any(n.startswith("lib/arm64-v8a/") for n in names):
        return 4, "this Kindle build has no arm64-v8a code"
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    try:
        certs = signer_certs(sys.argv[1])
    except (OSError, ValueError, struct.error, StopIteration) as e:
        print(f"apkcert: {e}", file=sys.stderr)
        sys.exit(2)
    if len(sys.argv) == 4 and sys.argv[2] in ("--expect", "--kindle"):
        if not (certs and all(c == sys.argv[3].lower() for c, _ in certs)):
            sys.exit(1)
        if sys.argv[2] == "--kindle":
            try:
                problem = kindle_build_problem(sys.argv[1])
            except (OSError, KeyError, zipfile.BadZipFile) as e:
                print(f"apkcert: {e}", file=sys.stderr)
                sys.exit(2)
            if problem:
                print(f"apkcert: {problem[1]}", file=sys.stderr)
                sys.exit(problem[0])
        sys.exit(0)
    for cert, scheme in certs:
        print(cert, scheme)


if __name__ == "__main__":
    main()
