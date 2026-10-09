#!/usr/bin/env python3
"""**A FILE THE REQUEST DOES NOT TOUCH SURVIVES A CUT, BYTE FOR BYTE**
(metal-vmm QUEUE 124(b)).

    tools/untouched.py PRISTINE UNHURT RUN

Each is a FAT16 or FAT32 volume, bare or the first partition of a GPT disk.
The files the request does not touch are those the unhurt run left as the
pristine volume had them, path and bytes. Each must be in RUN, unchanged.
Prints each that is not, and exits 1; exits 0 when every one is there.

Why: after a power cut `sound.sh` excuses what a stop leaves (STOP_LEAVES:
a leaked cluster, an orphaned long-name part, the FATs apart). A committed
file whose short entry was marked deleted reads to fsck as exactly that, an
orphaned long name and reclaimed clusters: a lost file passed as a stop's
leftovers. A file the request touches may rightly be old, new or gone
(store.zig's promises for a cut); one it does not touch has no excuse.

Read with gopher-metal's tools/fat16_read.py, written from Microsoft's FAT
specification: FAT_READ=<path> says where, else the gopher-metal checkout
beside this one.
"""
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def reader():
    path = os.environ.get("FAT_READ") or os.path.join(HERE, "..", "..", "gopher-metal", "tools", "fat16_read.py")
    if not os.path.isfile(path):
        raise SystemExit(f"untouched: no FAT reader at {path}; set FAT_READ=<gopher-metal's tools/fat16_read.py>")
    spec = importlib.util.spec_from_file_location("fat16_read", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def files(fat, image):
    """{path, case folded: (path, sha256 of its bytes, or None if they cannot
    be read)} for every file on the volume."""
    v = fat.load(image)
    problems = []
    out = {}
    for full, is_dir, first, size in v.walk(problems):
        if is_dir:
            continue
        try:
            data = b"" if size == 0 else b"".join(v.cluster(c) for c in v.chain(first))[:size]
            digest = hashlib.sha256(data).hexdigest() if len(data) == size else None
        except fat.Problem:
            digest = None
        out[full.casefold()] = (full, digest)
    return out


def lost(fat, pristine, unhurt, run):
    """What RUN lost of the files the request does not touch, as lines."""
    before = files(fat, pristine)
    after = files(fat, unhurt)
    got = files(fat, run)
    out = []
    for key, (path, digest) in sorted(before.items()):
        if digest is None or after.get(key, (None, None))[1] != digest:
            continue  # touched (changed or removed by the unhurt run), or unreadable before
        if key not in got:
            out.append(f"{path}: gone")
        elif got[key][1] != digest:
            out.append(f"{path}: changed" if got[key][1] is not None else f"{path}: cannot be read")
    return out


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    fat = reader()
    try:
        out = lost(fat, *argv[1:])
    except fat.Problem as p:
        print(f"  not a FAT volume: {p}")
        return 1
    for line in out:
        print(f"  {line}")
    return 1 if out else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
