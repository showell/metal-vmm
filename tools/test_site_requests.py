#!/usr/bin/env python3
"""Tests for tools/site_requests.py, on a FAT16 volume made here, its conf
under its long name as the site's is.

    python3 tools/test_site_requests.py   # FAT_READ=<fat16_read.py> if not beside
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_untouched as T  # noqa: E402
import untouched as U  # noqa: E402

TOOL = os.path.join(HERE, "site_requests.py")


def with_conf(text, other=b"untouched bytes\n"):
    """A volume holding OTHER.TXT and `gopher-metal.conf` (its long name in
    two LFN entries before its short one) saying `text`."""
    img = T.volume({"OTHER.TXT": other, "GOPHER~1.CON": text})
    fat = U.reader()
    short_at = T.ROOT * 512 + 32
    short = bytes(img[short_at:short_at + 11])
    # Room for the two LFN entries ahead of the short one: the short entry
    # moves down two slots.
    entry = bytes(img[short_at:short_at + 32])
    img[short_at + 64:short_at + 96] = entry
    name = "gopher-metal.conf"
    units = [ord(c) for c in name] + [0] + [0xFFFF] * (26 - len(name) - 1)
    for k, ordinal in ((0, 0x42), (1, 0x01)):
        part = units[13:26] if ordinal & 0x0F == 2 else units[0:13]
        e = bytearray(32)
        e[0] = ordinal
        e[11] = 0x0F
        e[13] = fat.lfn_checksum(short)
        struct.pack_into("<5H", e, 1, *part[0:5])
        struct.pack_into("<6H", e, 14, *part[5:11])
        struct.pack_into("<2H", e, 28, *part[11:13])
        img[short_at + 32 * k:short_at + 32 * (k + 1)] = e
    return img


class SiteRequests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fat = U.reader()

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, img, n):
        site = os.path.join(self.tmp.name, "site.img")
        out = os.path.join(self.tmp.name, "out.img")
        with open(site, "wb") as f:
            f.write(img)
        done = subprocess.run([sys.executable, TOOL, site, out, str(n)], capture_output=True, text=True)
        return done, site, out

    def conf(self, path):
        return self.fat.load(path).read("gopher-metal.conf")

    def test_the_limit_is_raised_and_nothing_else_moves(self):
        text = b"# the site\nrequests = 1\nidle_timeout_ms = 2000\n"
        done, site, out = self.run_tool(with_conf(text), 2)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.conf(out), b"# the site\nrequests = 2\nidle_timeout_ms = 2000\n")
        self.assertEqual(self.conf(site), text)  # the site itself as it was
        self.assertEqual(self.fat.load(out).read("OTHER.TXT"), b"untouched bytes\n")
        self.assertEqual(self.fat.load(out).check(), [])
        # Only the digit's byte differs.
        with open(site, "rb") as f, open(out, "rb") as g:
            a, b = f.read(), g.read()
        self.assertEqual(sum(x != y for x, y in zip(a, b)), 1)

    def test_fewer_digits_are_padded_more_are_refused(self):
        done, _, out = self.run_tool(with_conf(b"requests = 10\n"), 12)
        self.assertEqual(self.conf(out), b"requests = 12\n")
        done, _, out = self.run_tool(with_conf(b"requests = 1  \n"), 100)
        self.assertEqual(self.conf(out), b"requests = 100\n")
        done, _, _ = self.run_tool(with_conf(b"requests = 1\n"), 10)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("does not fit", done.stderr)

    def test_a_limit_already_enough_is_kept(self):
        done, _, out = self.run_tool(with_conf(b"requests = 8\n"), 2)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(self.conf(out), b"requests = 8\n")

    def test_no_limit_is_refused(self):
        done, _, _ = self.run_tool(with_conf(b"idle_timeout_ms = 2000\n"), 2)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("0 `requests` lines", done.stderr)


if __name__ == "__main__":
    unittest.main()
