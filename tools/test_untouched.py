#!/usr/bin/env python3
"""Tests for tools/untouched.py, on FAT16 volumes made here from the spec
(no mkfs.vfat: this runs where there is none).

    python3 tools/test_untouched.py     # FAT_READ=<fat16_read.py> if not beside
"""
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import untouched as U  # noqa: E402

SECTORS, RESERVED, FAT_SECTORS, ROOT_ENTRIES = 8192, 1, 33, 512
ROOT = RESERVED + 2 * FAT_SECTORS
DATA = ROOT + ROOT_ENTRIES * 32 // 512


def volume(files):
    """A FAT16 volume of 4 MiB, one sector a cluster, holding `files`
    ({"A.TXT": bytes}) in its root, each in consecutive clusters."""
    img = bytearray(SECTORS * 512)
    struct.pack_into("<3s8sHBHBHHBH", img, 0, b"\xeb\x3c\x90", b"MSWIN4.1", 512, 1, RESERVED, 2, ROOT_ENTRIES, SECTORS, 0xF8, FAT_SECTORS)
    img[38] = 0x29
    img[43:54] = b"NO NAME    "
    img[54:62] = b"FAT16   "
    img[510:512] = b"\x55\xaa"
    fat = {0: 0xFFF8, 1: 0xFFFF}
    nxt = 2
    for k, (name, data) in enumerate(files.items()):
        n = (len(data) + 511) // 512
        first = nxt if n else 0
        for i in range(n):
            fat[nxt + i] = nxt + i + 1 if i + 1 < n else 0xFFFF
            at = (DATA + nxt + i - 2) * 512
            img[at:at + 512] = data[i * 512:(i + 1) * 512].ljust(512, b"\0")
        nxt += n
        base, _, ext = name.partition(".")
        entry = (ROOT * 512) + 32 * k
        img[entry:entry + 11] = base.ljust(8).encode() + ext.ljust(3).encode()
        img[entry + 11] = 0x20
        struct.pack_into("<HI", img, entry + 26, first, len(data))
    for copy in range(2):
        for c, v in fat.items():
            struct.pack_into("<H", img, (RESERVED + copy * FAT_SECTORS) * 512 + 2 * c, v)
    return img


def tombstone(img, k):
    """The kth root entry marked deleted, as a stop part-way through a
    remove leaves it: its clusters still marked used."""
    img[ROOT * 512 + 32 * k] = 0xE5


class Untouched(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fat = U.reader()

    def tearDown(self):
        self.tmp.cleanup()

    def lost(self, pristine, unhurt, run):
        paths = []
        for name, img in (("p", pristine), ("u", unhurt), ("r", run)):
            path = os.path.join(self.tmp.name, name)
            with open(path, "wb") as f:
                f.write(img)
            paths.append(path)
        return U.lost(self.fat, *paths)

    def test_a_cut_that_kept_every_file_the_request_does_not_touch(self):
        pristine = volume({"A.TXT": b"a" * 700, "B.TXT": b"b" * 900})
        unhurt = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        self.assertEqual(self.lost(pristine, unhurt, unhurt), [])

    def test_a_file_it_does_not_touch_lost_as_a_stops_leftovers(self):
        # fsck reads this as an orphaned long name and reclaimed clusters:
        # what STOP_LEAVES excuses.
        pristine = volume({"A.TXT": b"a" * 700, "B.TXT": b"b" * 900})
        unhurt = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        run = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        tombstone(run, 1)
        self.assertEqual(self.lost(pristine, unhurt, run), ["/B.TXT: gone"])

    def test_a_file_it_does_not_touch_changed(self):
        pristine = volume({"A.TXT": b"a" * 700, "B.TXT": b"b" * 900})
        unhurt = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        run = volume({"A.TXT": b"A" * 700, "B.TXT": b"x" * 900})
        self.assertEqual(self.lost(pristine, unhurt, run), ["/B.TXT: changed"])

    def test_a_file_it_touches_may_be_gone_or_old(self):
        pristine = volume({"A.TXT": b"a" * 700, "B.TXT": b"b" * 900})
        unhurt = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        gone = volume({"A.TXT": b"A" * 700, "B.TXT": b"b" * 900})
        tombstone(gone, 0)
        self.assertEqual(self.lost(pristine, unhurt, gone), [])
        self.assertEqual(self.lost(pristine, unhurt, pristine), [])


if __name__ == "__main__":
    unittest.main()
