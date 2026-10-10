#!/usr/bin/env python3
"""**A FILE THE REQUEST DOES NOT TOUCH SURVIVES A CUT, BYTE FOR BYTE**
(metal-vmm QUEUE 124(b)).

    tools/untouched.py PRISTINE UNHURT RUN
    tools/untouched.py --ready      # 0 if the FAT reader loads, else 1, saying where it looked

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


class CannotJudge(Exception):
    """A baseline (the pristine or the unhurt volume) that cannot be walked
    whole: what it could not show would never be checked in the run."""


def files(fat, image, baseline=False):
    """{path, case folded: (path, sha256 of its bytes, or None if they cannot
    be read)} for every file on the volume. **A BASELINE IS WALKED WHOLE OR
    NOT AT ALL** (the normalization hunt, 2026-10-10): for one, a problem in
    its walk, a file that cannot be read, or two names that are one to FAT
    raises CannotJudge, where they were skipped."""
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
        key = full.casefold()
        if baseline and key in out:
            raise CannotJudge(f"{image}: {out[key][0]} and {full} are one name to FAT")
        if baseline and digest is None:
            raise CannotJudge(f"{image}: {full} cannot be read")
        out[key] = (full, digest)
    if baseline and problems:
        raise CannotJudge(f"{image}: {problems[0]}")
    return out


def lost(fat, pristine, unhurt, run):
    """What RUN lost of the files the request does not touch, as lines."""
    before = files(fat, pristine, baseline=True)
    after = files(fat, unhurt, baseline=True)
    got = files(fat, run)
    out = []
    for key, (path, digest) in sorted(before.items()):
        if digest is None or after.get(key, (None, None))[1] != digest:
            continue  # touched: changed or removed by the unhurt run
        if key not in got:
            out.append(f"{path}: gone")
        elif got[key][1] != digest:
            out.append(f"{path}: changed" if got[key][1] is not None else f"{path}: cannot be read")
    return out


def main(argv):
    # `--ready`: whether the FAT reader loads, asked before a sweep starts
    # (QUEUE 127(a)): a reader missing mid-night would read as a lost file.
    if argv[1:] == ["--ready"]:
        reader()
        return 0
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    fat = reader()
    try:
        out = lost(fat, *argv[1:])
    except fat.Problem as p:
        print(f"  not a FAT volume: {p}")
        return 1
    except CannotJudge as c:
        print(f"  cannot judge: {c}")
        return 2
    for line in out:
        print(f"  {line}")
    return 1 if out else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
