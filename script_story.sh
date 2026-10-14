#!/bin/bash
# **A SIGNED SCRIPT ON THE REAL SERVER, AND A DISK THAT FAILS UNDER IT**
# (metal-vmm QUEUE 200).
#
#   VOLUME_SITE=<the site's volume image> ./script_story.sh
#
# gopher.elf, its site disk and a copy of the volume, which this story gives
# what the script route needs (mtools: the volume is FAT): a test key's
# `auth/shale.conf` (target `metal-vmm.test`), and an admin (uid 1, a member)
# with a known API key. The key pair is made from a fixed seed, for this
# story only: it is not, and never becomes, the site's. Then, each a boot:
#
#   1. a request whose signature is wrong: refused (403), and the disk
#      commands a run makes without the script are counted;
#   2. the script, signed, unhurt: 200, finished, every effect ok, and the
#      commands with the script counted;
#   3. the script again (its own sequence number), on a fresh copy, with the
#      volume gone halfway between those two counts (VOLUME_GONE_AT): what
#      the reply says was done and not done, if a reply came;
#   4. the next boot, on the volume run 3 left, the disk whole again: the
#      log read back says the run started, and the same signed request is
#      refused as a replay (409): the restart finds its number used.
#
# The guest's clock is the host's (RTC_BOOTS_AT), so the signer's expiry is
# the guest's too. Exit 0 when every step holds, 1 when one does not, 2 when
# it cannot be judged (a tool missing).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS="$(cd "$HERE/.." && pwd)"
GUESTS="${GUESTS:-$REPOS/zig-metal-unikernel/probe}"
WEBBOX="${WEBBOX_ROOT:-$REPOS/zig-webbox}"
SITE="${SITE:-$HOME/build/zig-metal-unikernel/probe/gopher/pristine.img}"
TARGET=metal-vmm.test
cannot() { echo "script story: CANNOT JUDGE: $*"; exit 2; }
for t in mcopy mmd mtype zig; do command -v "$t" > /dev/null || cannot "no $t"; done
[ -n "${VOLUME_SITE:-}" ] && [ -f "$VOLUME_SITE" ] || cannot "VOLUME_SITE=<the site's volume image> is needed"
[ -f "$GUESTS/gopher.elf" ] || cannot "no $GUESTS/gopher.elf"
[ -f "$SITE" ] || cannot "no site disk at $SITE"
. "$HERE/tools/fresh.sh"
fresh_vmm "$HERE"
VMM="$HERE/zig-out/bin/metal-vmm"
(cd "$WEBBOX" && zig build) || cannot "zig-webbox did not build (the signer)"
SIGN="$WEBBOX/zig-out/bin/shale-sign"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0
say() { echo "script story: $*"; }
bad() { say "FAIL: $*"; failed=1; }

# ── the volume, made ready ──────────────────────────────────────────────────
# The story's own key, from a fixed seed: the signer reads it from HOME.
mkdir -p "$WORK/home"
printf '%064d\n' 7 > "$WORK/home/.shale_signing_key"
chmod 600 "$WORK/home/.shale_signing_key"
PUB=$(HOME="$WORK/home" "$SIGN" pubkey) || cannot "the signer could not read the story's key"
API_KEY="1-00112233445566778899aabbccddeeff"
cp "$VOLUME_SITE" "$WORK/ready.vol"
for d in ::auth ::auth/1; do mmd -i "$WORK/ready.vol" "$d" 2> /dev/null; done
printf '%s\ntarget = %s\n' "$PUB" "$TARGET" | mcopy -o -i "$WORK/ready.vol" - ::auth/shale.conf || cannot "mcopy: shale.conf"
printf '%s' "$API_KEY" | mcopy -o -i "$WORK/ready.vol" - ::auth/1/api-key || cannot "mcopy: api-key"
mtype -i "$WORK/ready.vol" ::auth/1/password > /dev/null 2>&1 || printf 'story' | mcopy -o -i "$WORK/ready.vol" - ::auth/1/password

# Twenty small files, one at a time: changes enough that a disk can go
# between them.
{
    echo 'for i = 1, 20 do'
    echo '  replace("shale-story/f" .. i .. ".txt", "written by the story")'
    echo 'end'
    echo 'print("wrote twenty")'
} > "$WORK/story.shale"

NOW=$(date +%s)
sign() { # $1: the name of the request file to make
    HOME="$WORK/home" "$SIGN" sign "$WORK/story.shale" "$TARGET" 30 > /dev/null 2> "$WORK/sign.err" || cannot "the signer: $(cat "$WORK/sign.err")"
    local body
    body=$(ls -t "$WORK"/story.shale.*.req | head -1)
    {
        printf 'POST /admin/script HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' "$TARGET" "$API_KEY" "$(stat -c %s "$body")"
        cat "$body"
    } > "$1"
}

boot() { # $1 volume, $2 request; the knobs before; leaves out, err, response
    cp "$SITE" "$WORK/site.img"
    timeout 300 env RTC_BOOTS_AT="$NOW" PEER_REQUEST="$2" PEER_RESPONSE="$WORK/response" VOLUME="$1" "${KNOBS[@]}" "$VMM" "$GUESTS/gopher.elf" "$WORK/site.img" "" / > "$WORK/out" 2> "$WORK/err"
}
commands() { sed -n -E 's/^metal-vmm: volume: .*; ([0-9]+) reads, ([0-9]+) writes.*/\1 \2/p' "$WORK/err" | awk '{ print $1 + $2 }' | tail -1; }
status() { sed -n -E 's/^peer: ([0-9]+).*/\1/p' "$WORK/out" | head -1; }

# ── 1. a bad signature: refused, nothing run ────────────────────────────────
sign "$WORK/good.http"
# The first hex digit of the signature, changed: the body's length is the same.
python3 - "$WORK/good.http" "$WORK/forged.http" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
at = raw.index(b"shale-signature ") + len(b"shale-signature ")
raw = raw[:at] + (b"1" if raw[at:at + 1] == b"0" else b"0") + raw[at + 1:]
open(sys.argv[2], "wb").write(raw)
PY
cp "$WORK/ready.vol" "$WORK/v1.vol"
KNOBS=(); boot "$WORK/v1.vol" "$WORK/forged.http"
[ "$(status)" = 403 ] || bad "a forged signature answered $(status), not 403"
grep -q "refused (bad_signature)" "$WORK/response" 2> /dev/null || bad "a forged signature's reply does not say bad_signature"
BEFORE=$(commands)
say "1: forged, $(status), $BEFORE volume commands"

# ── 2. the script, unhurt ───────────────────────────────────────────────────
cp "$WORK/ready.vol" "$WORK/v2.vol"
KNOBS=(); boot "$WORK/v2.vol" "$WORK/good.http"
[ "$(status)" = 200 ] || bad "the script answered $(status), not 200"
grep -q "── effects (20) ──" "$WORK/response" || bad "the reply does not list twenty effects"
grep -q "── finished (" "$WORK/response" || bad "the script did not finish unhurt"
grep -q "── memory rebuilt from the store" "$WORK/response" || bad "the reply does not say memory was rebuilt"
AFTER=$(commands)
say "2: unhurt, $(status), $AFTER volume commands"
[ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$AFTER" -gt "$BEFORE" ] || cannot "the volume's command counts did not read ($BEFORE, $AFTER)"

# ── 3. the disk gone mid-run ────────────────────────────────────────────────
sign "$WORK/third.http"
GONE=$(( (BEFORE + AFTER) / 2 ))
cp "$WORK/ready.vol" "$WORK/v3.vol"
KNOBS=(VOLUME_GONE_AT="$GONE"); boot "$WORK/v3.vol" "$WORK/third.http"
got=$(status)
say "3: the volume gone from command $GONE: the reply ${got:-never came}"
if [ -n "$got" ]; then
    # A reply that came says what was done: each effect ok or its error,
    # and how the run ended; a log that could not be written, loudly.
    sed -n '/^── effects/,$p' "$WORK/response" | sed 's/^/    /'
    oks=$(grep -c ': ok$' "$WORK/response")
    errs=$(grep -cE '^replace shale-story/f[0-9]+\.txt: [A-Z]' "$WORK/response")
    [ $(( oks + errs )) -ge 1 ] || bad "the reply names no effect, done or not"
    if ! grep -q "THE LOG WAS NOT WRITTEN" "$WORK/response" && [ "$got" != 200 ]; then bad "a run answered $got without saying its log failed"; fi
    [ "$got" = 200 ] || [ "$got" = 500 ] || bad "a run that started answered $got"
else
    say "  (no reply: the kernel restarted on the stopped disk, restart.zig's disk_stopped; step 4 is what is left)"
fi

# ── 4. the restart: the number is used ──────────────────────────────────────
KNOBS=(); boot "$WORK/v3.vol" "$WORK/third.http"
[ "$(status)" = 409 ] || bad "the same request after the restart answered $(status), not 409 (replayed)"
mtype -i "$WORK/v3.vol" ::auth/shale/log > "$WORK/log" 2> /dev/null || bad "no log on the volume"
seq3=$(sed -n -E 's/.*sequence=([0-9]+).*/\1/p' "$WORK/third.http" | head -1)
grep -q "seq=$seq3 sha256=.* started" "$WORK/log" || bad "the log does not say run $seq3 started"
say "4: the restart, $(status); the log on the volume for run $seq3:"
grep "seq=$seq3 " "$WORK/log" | sed 's/^/    /'

if [ "$failed" = 0 ]; then say PASS; exit 0; fi
say FAIL
exit 1
