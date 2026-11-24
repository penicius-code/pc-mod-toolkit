"""List the PE resources (type/name/lang, size, sha256) of one or more DLLs and show which resource blobs are
byte-identical across files. Read-only. Useful to see what actually differs between two builds of a DLL
when their version numbers say little.

Usage: python -I pe_resources.py <label=path.dll> [...]
"""
import hashlib
import struct
import sys


def sections(d):
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    n = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    magic = struct.unpack_from("<H", d, pe + 24)[0]
    dd = pe + 24 + (112 if magic == 0x20B else 96)
    rsrc_rva = struct.unpack_from("<I", d, dd + 2 * 8)[0]
    secs = []
    for i in range(n):
        o = pe + 24 + opt + i * 40
        vsize, va, rsize, raw = struct.unpack_from("<IIII", d, o + 8)
        secs.append((va, max(vsize, rsize), raw))
    return rsrc_rva, secs


def rva2off(secs, rva):
    for va, size, raw in secs:
        if va <= rva < va + size:
            return rva - va + raw
    raise ValueError(hex(rva))


def name_of(d, base, entry_name):
    if entry_name & 0x80000000:
        o = base + (entry_name & 0x7FFFFFFF)
        ln = struct.unpack_from("<H", d, o)[0]
        return d[o + 2:o + 2 + ln * 2].decode("utf-16le", "replace")
    return str(entry_name)


def walk(d, secs, base, off, path, out):
    named, ids = struct.unpack_from("<HH", d, off + 12)
    for i in range(named + ids):
        name, target = struct.unpack_from("<II", d, off + 16 + i * 8)
        nm = name_of(d, base, name)
        if target & 0x80000000:
            walk(d, secs, base, base + (target & 0x7FFFFFFF), path + [nm], out)
        else:
            data_rva, size = struct.unpack_from("<II", d, base + target)
            o = rva2off(secs, data_rva)
            blob = d[o:o + size]
            out.append(("/".join(path + [nm]), size, hashlib.sha256(blob).hexdigest()))


def resources(path):
    d = open(path, "rb").read()
    rsrc_rva, secs = sections(d)
    base = rva2off(secs, rsrc_rva)
    out = []
    walk(d, secs, base, base, [], out)
    return out


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    files = [a.split("=", 1) for a in sys.argv[1:]]
    allres = {}
    for label, path in files:
        res = resources(path)
        allres[label] = res
        big = [r for r in res if r[1] > 1_000_000]
        print(f"== {label}: {len(res)} resources, {sum(r[1] for r in res) / 1e6:.1f} MB total; blobs > 1 MB:")
        for p, size, h in big:
            print(f"   {p:<40} {size:>11}  {h[:16]}")
    print("\n== identical large blobs across files (by sha256):")
    seen = {}
    for label, res in allres.items():
        for p, size, h in res:
            if size > 1_000_000:
                seen.setdefault(h, []).append(f"{label}:{p}")
    for h, where in seen.items():
        print(f"   {h[:16]}  {' = '.join(where)}")


if __name__ == "__main__":
    main()
