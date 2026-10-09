#!/usr/bin/env python3
"""**A SITE THAT SERVES n REQUESTS** (metal-vmm QUEUE 127(h)).

    tools/site_requests.py SITE OUT N

Copies the boot disk SITE to OUT with its `gopher-metal.conf` saying
`requests = N`, where it said fewer. The site's own limit (1) is what ends a
run, so a shape of n clients would be served only its first: sweep.sh boots
such a shape from a copy made here.

The number is written in place, over the old one's digits (padded with
spaces, which the kernel's parser trims), so the file keeps its length and
no cluster, entry or FAT changes: nothing the volume's soundness rests on is
touched. A number with more digits than the old one is refused, as is a conf
with no `requests` line (a site that serves forever needs no raising) and
one that already says N or more (copied unchanged).

Read with gopher-metal's tools/fat16_read.py, as untouched.py reads.
"""
import mmap
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from untouched import reader  # noqa: E402

CONF = "/gopher-metal.conf"
LINE = re.compile(rb"^([ \t]*requests[ \t]*=[ \t]*)([0-9]+)([ \t]*)\r?$", re.M)


def raise_requests(path, n):
    """Raises the conf's limit in the image at `path`, in place. Returns what
    it said before."""
    fat = reader()
    with open(path, "r+b") as f:
        img = mmap.mmap(f.fileno(), 0)
        try:
            v = fat.Volume(img)
            entry = None
            for full, is_dir, first, size in v.walk([]):
                if full.casefold() == CONF.casefold() and not is_dir:
                    entry = (first, size)
            if entry is None:
                raise SystemExit(f"site_requests: no {CONF} on the site")
            first, size = entry
            chain = v.chain(first)
            text = b"".join(v.cluster(c) for c in chain)[:size]
            found = list(LINE.finditer(text))
            if len(found) != 1:
                raise SystemExit(f"site_requests: {CONF} has {len(found)} `requests` lines, not one")
            m = found[0]
            old = int(m.group(2))
            if old >= n:
                return old
            room = len(m.group(2)) + len(m.group(3))
            digits = str(n).encode()
            if len(digits) > room:
                raise SystemExit(f"site_requests: {n} does not fit where {CONF} says {old}")
            new = digits + b" " * (room - len(digits))
            for k, byte in enumerate(new):
                at = m.start(2) + k
                c = chain[at // v.cluster_bytes]
                img[v.base + (v.data_start + (c - 2) * v.spc) * fat.SECTOR + at % v.cluster_bytes] = byte
            img.flush()
            return old
        finally:
            img.close()


def main(argv):
    if len(argv) != 4 or not argv[3].isdigit() or int(argv[3]) < 1:
        print(__doc__, file=sys.stderr)
        return 2
    shutil.copyfile(argv[1], argv[2])
    old = raise_requests(argv[2], int(argv[3]))
    print(f"{CONF}: requests = {max(old, int(argv[3]))} (was {old})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
