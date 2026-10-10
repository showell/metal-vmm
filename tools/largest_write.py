#!/usr/bin/env python3
"""**THE MOST CLUSTERS ONE OPERATION OF A REQUEST WRITES**, read off its unhurt run.

    tools/largest_write.py PRISTINE UNHURT

Each is a FAT16 or FAT32 volume, bare or the first partition of a GPT disk.
Prints one number: the clusters of the largest file the unhurt run left new
or changed (against the pristine volume), plus one for a folder that grew.

Why: a power cut stops one operation part way (one handler at a time), and
what it can leave behind is at most the chain of the file it was writing and
a folder's new cluster (`sweep.sh` `stop_leftovers`). The request bodies are
no bound (a 221-byte puzzle move rewrites a 37 KB file); the unhurt run of
the same shape says what its operations write.

Read with gopher-metal's tools/fat16_read.py, as untouched.py is: FAT_READ=<path>
says where, else the gopher-metal checkout beside this one.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import untouched  # noqa: E402  (its reader and its walk of files)


def largest(fat, pristine, unhurt):
    before = untouched.files(fat, pristine, baseline=True)
    after = untouched.files(fat, unhurt, baseline=True)
    v = fat.load(unhurt)
    most = 0
    for key, (path, digest) in after.items():
        if digest is not None and before.get(key, (None, None))[1] == digest:
            continue  # untouched by the request
        size = v_size(v, path)
        most = max(most, (size + v.cluster_bytes - 1) // v.cluster_bytes)
    return most + 1


def v_size(v, path):
    """The size of `path` on volume `v`, from its directory entry."""
    problems = []
    for full, is_dir, first, size in v.walk(problems):
        if full == path:
            return size
    raise SystemExit(f"largest_write: {path} listed and then not found")


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    fat = untouched.reader()
    try:
        print(largest(fat, argv[1], argv[2]))
    except (fat.Problem, untouched.CannotJudge) as p:
        print(f"largest_write: {p}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
