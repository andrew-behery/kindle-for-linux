#!/usr/bin/env python3
"""Save an APK's launcher icon (its sharpest bitmap version) to a file.

    apkicon.py app.apk OUT   ->  writes OUT.png or OUT.webp (whichever the APK has), prints the path

Reads the manifest's android:icon resource, resolves it in resources.arsc across screen
densities, and copies the highest-density bitmap. Adaptive (XML) icons are skipped in favour of
the bitmap versions apps ship for older Android. Standard library only.
"""
import struct
import sys
import zipfile

ICON_ATTR = 0x01010002  # android:icon
ROUND_ICON_ATTR = 0x0101052C  # android:roundIcon


def string_pool(buf, off):
    """Strings of the ResStringPool chunk at off."""
    _type, header_size, _size = struct.unpack_from("<HHI", buf, off)
    count, _styles, flags, strings_start, _ = struct.unpack_from("<IIIII", buf, off + 8)
    offsets = struct.unpack_from(f"<{count}I", buf, off + header_size)
    base = off + strings_start
    utf8 = flags & 0x100
    out = []
    for o in offsets:
        p = base + o
        if utf8:
            n = buf[p]
            p += 2 if n & 0x80 else 1  # character count (skipped)
            n = buf[p]
            if n & 0x80:
                n = ((n & 0x7F) << 8) | buf[p + 1]
                p += 1
            p += 1
            out.append(buf[p : p + n].decode("utf-8", "replace"))
        else:
            (n,) = struct.unpack_from("<H", buf, p)
            p += 2
            if n & 0x8000:
                (lo,) = struct.unpack_from("<H", buf, p)
                n = ((n & 0x7FFF) << 16) | lo
                p += 2
            out.append(buf[p : p + 2 * n].decode("utf-16-le", "replace"))
    return out


def manifest_icon_ids(axml):
    """Resource IDs of <application>'s icon and roundIcon, from the binary manifest."""
    strings, resmap, found = [], [], {}
    off = struct.unpack_from("<H", axml, 2)[0]
    while off < len(axml):
        ctype, header_size, size = struct.unpack_from("<HHI", axml, off)
        if ctype == 0x0001:
            strings = string_pool(axml, off)
        elif ctype == 0x0180:
            resmap = struct.unpack_from(f"<{(size - header_size) // 4}I", axml, off + header_size)
        elif ctype == 0x0102:  # start element
            ext = off + header_size
            _ns, name, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", axml, ext)
            if strings[name] == "application":
                for i in range(attr_count):
                    a = ext + attr_start + i * attr_size
                    _ans, aname, _raw, _vsize, _res0, vtype, data = struct.unpack_from("<IIIHBBI", axml, a)
                    rid = resmap[aname] if aname < len(resmap) else 0
                    if rid in (ICON_ATTR, ROUND_ICON_ATTR) and vtype == 0x01:
                        found[rid] = data
                break
        off += size
    return [found[k] for k in (ICON_ATTR, ROUND_ICON_ATTR) if k in found]


def resource_files(arsc, res_id):
    """[(density, file path)] for a file resource, one per configuration."""
    pkg_id, type_id, entry_id = res_id >> 24, (res_id >> 16) & 0xFF, res_id & 0xFFFF
    _t, header_size, _s = struct.unpack_from("<HHI", arsc, 0)
    off = header_size
    values = []
    out = []
    while off < len(arsc):
        ctype, chs, size = struct.unpack_from("<HHI", arsc, off)
        if ctype == 0x0001 and not values:
            values = string_pool(arsc, off)
        elif ctype == 0x0200:  # package
            (pid,) = struct.unpack_from("<I", arsc, off + 8)
            if pid == pkg_id:
                sub = off + chs
                while sub < off + size:
                    stype, shs, ssize = struct.unpack_from("<HHI", arsc, sub)
                    if stype == 0x0201:
                        tid, flags, _r, count, entries_start = struct.unpack_from("<BBHII", arsc, sub + 8)
                        if tid == type_id:
                            config = sub + 20
                            (density,) = struct.unpack_from("<H", arsc, config + 14)
                            index = sub + shs
                            eoff = None
                            if flags & 0x01:  # sparse: (entry index, offset / 4) pairs
                                for i in range(count):
                                    idx, o = struct.unpack_from("<HH", arsc, index + 4 * i)
                                    if idx == entry_id:
                                        eoff = o * 4
                                        break
                            elif entry_id < count:
                                if flags & 0x02:  # 16-bit offsets / 4
                                    (o,) = struct.unpack_from("<H", arsc, index + 2 * entry_id)
                                    eoff = None if o == 0xFFFF else o * 4
                                else:
                                    (o,) = struct.unpack_from("<I", arsc, index + 4 * entry_id)
                                    eoff = None if o == 0xFFFFFFFF else o
                            if eoff is not None:
                                e = sub + entries_start + eoff
                                esize, eflags = struct.unpack_from("<HH", arsc, e)
                                if eflags & 0x08:  # compact entry: type in the flags' high byte
                                    vtype, (data,) = eflags >> 8, struct.unpack_from("<I", arsc, e + 4)
                                elif not eflags & 0x01:  # a simple value follows the entry
                                    _vs, _z, vtype, data = struct.unpack_from("<HBBI", arsc, e + esize)
                                else:
                                    vtype = None
                                if vtype == 0x03:
                                    out.append((density, values[data]))
                    sub += ssize
        off += size
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    apk, out = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(apk) as z:
        ids = manifest_icon_ids(z.read("AndroidManifest.xml"))
        arsc = z.read("resources.arsc")
        for rid in ids:
            # Highest density first; 0xFFFE/0xFFFF (any/no density) rank below real densities.
            files = [(d if d < 0xFFFE else 0, p) for d, p in resource_files(arsc, rid)]
            bitmaps = sorted((f for f in files if f[1].endswith((".png", ".webp"))), reverse=True)
            if bitmaps:
                path = bitmaps[0][1]
                dest = out + path[path.rfind(".") :]
                with open(dest, "wb") as f:
                    f.write(z.read(path))
                print(dest)
                return
    sys.exit("apkicon: no bitmap launcher icon found")


if __name__ == "__main__":
    main()
