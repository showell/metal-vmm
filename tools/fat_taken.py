#!/usr/bin/env python3
"""**HOW MANY CLUSTERS THE FIRST FAT MARKS TAKEN**: every one not free.

    tools/fat_taken.py IMAGE

IMAGE is a FAT16 or FAT32 volume, bare or the first partition of a GPT disk.
Prints one number.

Why: fsck.fat -n says a chain longer than its file's size only as "cluster
chain length is > N bytes", and counts what it would cut neither as in use
nor as reclaimed. So the clusters past every size are exactly the taken ones
less fsck's in-use count less what it reclaimed (a cluster marked bad is
in fsck's in-use count, so it is taken here too: 3666418's review), which `sweep.sh`'s
counted_leak holds to the kernel's own count (metal-vmm 148(c)). fsck uses
the first FAT, so this does too.

Read with gopher-metal's tools/fat16_read.py, as untouched.py is: FAT_READ=<path>
says where, else the gopher-metal checkout beside this one.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def reader():
    path = os.environ.get("FAT_READ") or os.path.join(HERE, "..", "..", "gopher-metal", "tools", "fat16_read.py")
    if not os.path.isfile(path):
        raise SystemExit(f"fat_taken: no FAT reader at {path}; set FAT_READ=<gopher-metal's tools/fat16_read.py>")
    spec = importlib.util.spec_from_file_location("fat16_read", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def taken(fat, image):
    v = fat.load(image)
    return sum(1 for c in range(2, v.max_cluster + 1) if v.fat(c) != 0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: fat_taken.py IMAGE")
    print(taken(reader(), sys.argv[1]))
