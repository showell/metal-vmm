#!/bin/bash
# **A TIMEOUT IS JUDGED IN THE MACHINE'S TIME, NOT THE HOST'S.**
#
#   ./timeouts.sh
#
# What a setting governs is proved by changing the setting and watching the
# moment move, and here that moment is read off the machine's own clock
# (each client's line says when it opened, was answered and was closed), so
# a six-second wait costs well under a second and the answer is exact and
# the same on every run. The checks that exist to prove a timeout fires
# live here rather than under QEMU, where the guest's clock is the host's.
#
# **A silent client holds nobody up, and is let go when the volume says.**
# On the PC-shaped machine, two clients: the first sends half a request
# (`requests/half-request.http`) and then nothing; the second asks for /.
# For each `idle_timeout_ms` in zig-metal-unikernel.conf:
#   - the second is answered within a second of opening, before the first
#     is let go: it does not wait behind the silent one;
#   - the guest closes the first no sooner than the setting after it opened,
#     and within 50 ms after that;
#   - the guest serves its two requests and stops cleanly.
#
# **A reader that pauses gets every byte; one that pauses past the idle
# time is let go, and holds nobody up.** The first client asks for a page
# bigger than a connection's 64 KiB send queue
# (`requests/big-page.http`), so what it does not take waits as the
# kernel's spill, and shuts its window after 4 KiB (`PEER_SHUT_AFTER`). For
# each `idle_timeout_ms`, it reopens half a second before the setting, then
# half a second after:
#   - before: the whole page, as many bytes as an unhurt fetch, with the
#     window probed while it was shut;
#   - after: the kernel says it let the reader go, and the reader's next word
#     is answered with a reset;
#   - either way, a caller four seconds in (`requests/not-found.http`) is
#     answered within a second.
#
# **A SLOW BODY HOLDS NOBODY UP, AND IS ANSWERED WHEN THE RULE SAYS**
# (webbox's body.zig, metal-vmm QUEUE 166). The first client sends a chunked
# POST 16 bytes every 3 s (`requests/trickle-chunked.http`: its head whole in
# its sixth segment, about 15 s in, its last chunk in its eighth, about 21 s
# in); the second asks for / at 17 s:
#   - the second is answered within a second of opening, before the first:
#     a body that fits the buffer is waited for before the turn, never in it
#     (the kernel of v26 served the first at its head and read its body in
#     the turn, a read at a time, so the second waited for all of it);
#   - the first, its body whole within the rule's 10 s of its head, is
#     answered by its route (404), after the second.
# Then alone, 16 bytes every 5 s and a longer body
# (`requests/trickle-chunked-long.http`: its head whole about 25 s in, its
# last chunk about 40 s in): a 408 at the rule's 11 s (10 s and its route's 64 KiB at 64 KiB/s) after its head was
# whole, where v26 read it to its end and answered 404.
#
# **A SLOW UPLOADER HOLDS NOBODY UP** (metal-vmm QUEUE 169: the turn never
# waits on the network). The first client sends a 64,000-byte form to
# `POST /login/full` (whose route reads its body for anyone) at about
# 64 KB/s, 1460 bytes every 22 ms, about a second in all: a body too big for
# a connection's 16 KiB buffer, which the kernel now drains into memory
# before the turn. The second asks for / 300 ms in:
#   - the second is answered within 100 ms of opening, before the first (v26
#     served the first at its head and read its body in the turn, so the
#     second waited most of a second);
#   - the first is answered by its route, not a 408.
#
# Needs: a built metal-vmm, gopher.elf, the site's boot disk (SITE, as the
# other scripts have it) and mtools (`mcopy`) to write its config.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zig-metal-unikernel/probe}"
. "$HERE/tools/fresh.sh"
[ -n "${KERNEL:-}" ] || fresh_kernel "$GUESTS/gopher.elf" "$(dirname "$GUESTS")"
KERNEL="${KERNEL:-$GUESTS/gopher.elf}"
SITE="${SITE:-$HOME/build/zig-metal-unikernel/site/pristine.img}"
fresh_vmm "$HERE"
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 2; }
[ -f "$KERNEL" ] || { echo "no $KERNEL; in zig-metal-unikernel: zig build gopher"; exit 2; }
[ -f "$SITE" ] || { echo "no site disk at $SITE; set SITE=<image>"; exit 2; }
command -v mcopy > /dev/null || { echo "no mcopy: install mtools"; exit 2; }

# The first partition of a GPT disk from mkfs.vfat starts at sector 2048.
PART=$((2048 * 512))
failed=0
fail() { echo "FAIL  $*"; failed=1; }

# us_of <line> <mark>: that mark's time, in whole microseconds.
us_of() { sed -n -E "s/.*, $2 at ([0-9]+)\.([0-9]{3}) ms.*/\1\2/p" <<< "$1"; }

declare -A closed_after
for ms in 2000 6000; do
    cp "$SITE" "$WORK/boot.img"
    cp "$SITE" "$WORK/vol.img"
    printf 'requests = 2\nidle_timeout_ms = %s\n' "$ms" > "$WORK/conf"
    mcopy -o -i "$WORK/boot.img@@$PART" "$WORK/conf" ::zig-metal-unikernel.conf ||
        { echo "could not write zig-metal-unikernel.conf"; exit 2; }
    TRANSPORT=pci PEER_CLIENTS=2 VOLUME="$WORK/vol.img" \
        PEER_REQUEST="$HERE/requests/half-request.http,$HERE/requests/shapes/home.http" \
        timeout 120 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
    code=$?
    silent=$(grep '^peer 1: ' "$WORK/out")
    caller=$(grep '^peer 2: ' "$WORK/out")
    if [ "$code" != 0 ] || ! grep -q '^  served 2 request(s)' "$WORK/out"; then
        fail "silent client, idle_timeout_ms=$ms: the guest did not serve its two requests and stop (exit $code): $(tail -1 "$WORK/err")"
        continue
    fi
    s_open=$(us_of "$silent" opened); s_closed=$(us_of "$silent" "the guest closed")
    c_open=$(us_of "$caller" opened); c_answered=$(us_of "$caller" answered)
    if [ -z "$s_closed" ] || [ -z "$c_answered" ] || ! grep -q '^peer 2: 200,' <<< "$caller"; then
        fail "silent client, idle_timeout_ms=$ms: $silent | $caller"
        continue
    fi
    waited=$(( c_answered - c_open )); let_go=$(( s_closed - s_open ))
    closed_after[$ms]=$let_go
    [ "$waited" -lt 1000000 ] && [ "$c_answered" -lt "$s_closed" ] ||
        fail "silent client, idle_timeout_ms=$ms: the caller waited $((waited / 1000)) ms, held up behind the silent one"
    [ "$let_go" -ge $(( ms * 1000 )) ] && [ "$let_go" -le $(( ms * 1000 + 50000 )) ] ||
        fail "silent client, idle_timeout_ms=$ms: let go $((let_go / 1000)) ms after it opened, not at the setting"
    [ "$failed" = 0 ] && echo "      idle_timeout_ms=$ms: the caller answered in $((waited / 1000)) ms; the silent one let go after $((let_go / 1000)) ms"
done

# The unhurt fetch: how big the page is, every byte of it.
cp "$SITE" "$WORK/boot.img"; cp "$SITE" "$WORK/vol.img"
TRANSPORT=pci VOLUME="$WORK/vol.img" PEER_REQUEST="$HERE/requests/big-page.http" \
    timeout 120 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
page=$(sed -n -E 's/^peer: 200, ([0-9]+) bytes$/\1/p' "$WORK/out")
[ -n "$page" ] && [ "$page" -gt 65536 ] || { echo "the big page was not a 200 past 64 KiB: $(grep '^peer:' "$WORK/out")"; exit 2; }

for ms in 3000 5000; do
    before=$failed; failed=0
    for late in no yes; do
        if [ "$late" = no ]; then paused=$(( ms - 500 )); else paused=$(( ms + 500 )); fi
        cp "$SITE" "$WORK/boot.img"; cp "$SITE" "$WORK/vol.img"
        printf 'requests = 3\nidle_timeout_ms = %s\n' "$ms" > "$WORK/conf"
        mcopy -o -i "$WORK/boot.img@@$PART" "$WORK/conf" ::zig-metal-unikernel.conf ||
            { echo "could not write zig-metal-unikernel.conf"; exit 2; }
        TRANSPORT=pci PEER_CLIENTS=3 PEER_CLIENT_GAP_US=4000000 VOLUME="$WORK/vol.img" \
            PEER_REQUEST="$HERE/requests/big-page.http,$HERE/requests/not-found.http" \
            PEER_SHUT_AFTER=4096 PEER_SHUT_FOR_US=$(( paused * 1000 )) \
            timeout 120 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
        code=$?
        what="a reader paused $paused ms, idle_timeout_ms=$ms"
        reader=$(grep '^peer 1: ' "$WORK/out")
        caller=$(grep '^peer 2: ' "$WORK/out")
        probes=$(sed -n -E 's/.*tcp: .*, ([0-9]+) window probes,.*/\1/p' "$WORK/out")
        if [ "$code" != 0 ] || ! grep -q '^  served 3 request(s)' "$WORK/out"; then
            fail "$what: the guest did not serve its three requests and stop (exit $code): $(tail -1 "$WORK/err")"
            continue
        fi
        c_open=$(us_of "$caller" opened); c_answered=$(us_of "$caller" answered)
        [ -n "$c_answered" ] && [ $(( c_answered - c_open )) -lt 1000000 ] ||
            fail "$what: the caller beside it was not answered within a second: $caller"
        if [ "$late" = no ]; then
            # Whole by its own length (an answer is counted only then), and
            # past the unhurt body by no more than its head.
            got=$(sed -n -E 's/^peer 1: 200, 1 of 1 answers, ([0-9]+) bytes, done,.*/\1/p' <<< "$reader")
            [ -n "$got" ] && [ "$got" -gt "$page" ] && [ "$got" -lt $(( page + 1024 )) ] ||
                fail "$what: not the whole page: $reader (unhurt: $page bytes of body)"
            [ "${probes:-0}" -gt 0 ] || fail "$what: no window probes while it paused, so its window never shut"
            grep -q 'stopped taking the response' "$WORK/out" && fail "$what: let go before the idle time"
        else
            grep -q '^  let go: the client stopped taking the response' "$WORK/out" ||
                fail "$what: the kernel never said it let the reader go"
            grep -q ", refused," <<< "$reader" ||
                fail "$what: the reader's next word was not answered with a reset: $reader"
        fi
    done
    [ "$failed" = 0 ] && echo "      idle_timeout_ms=$ms: paused $(( ms - 500 )) ms, the whole page; paused $(( ms + 500 )) ms, let go"
    [ "$before" = 0 ] || failed=1
done

# A slow body (QUEUE 166). Derived from the rule and the peer's segments,
# not yet run on a guest when written (CC's container has no KVM).
before=$failed; failed=0
cp "$SITE" "$WORK/boot.img"; cp "$SITE" "$WORK/vol.img"
printf 'requests = 2\n' > "$WORK/conf"
mcopy -o -i "$WORK/boot.img@@$PART" "$WORK/conf" ::zig-metal-unikernel.conf ||
    { echo "could not write zig-metal-unikernel.conf"; exit 2; }
TRANSPORT=pci PEER_CLIENTS=2 PEER_CLIENT_GAP_US=17000000 VOLUME="$WORK/vol.img" \
    PEER_REQUEST="$HERE/requests/trickle-chunked.http,$HERE/requests/shapes/home.http" \
    PEER_MSS=16 PEER_DRIP_US=3000000 \
    timeout 300 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
code=$?
slow=$(grep '^peer 1: ' "$WORK/out")
caller=$(grep '^peer 2: ' "$WORK/out")
if [ "$code" != 0 ] || ! grep -q '^  served 2 request(s)' "$WORK/out"; then
    fail "slow body: the guest did not serve its two requests and stop (exit $code): $(tail -1 "$WORK/err")"
else
    c_open=$(us_of "$caller" opened); c_answered=$(us_of "$caller" answered)
    s_answered=$(us_of "$slow" answered)
    { [ -n "$c_answered" ] && grep -q '^peer 2: 200,' <<< "$caller" && [ $(( c_answered - c_open )) -lt 1000000 ]; } ||
        fail "slow body: the caller beside a trickled chunked body was not answered within a second: $caller"
    { [ -n "$s_answered" ] && grep -q '^peer 1: 404,' <<< "$slow" && [ -n "$c_answered" ] && [ "$c_answered" -lt "$s_answered" ]; } ||
        fail "slow body: the trickled body was not answered by its route after the caller: $slow | $caller"
fi
cp "$SITE" "$WORK/boot.img"; cp "$SITE" "$WORK/vol.img"
printf 'requests = 1\n' > "$WORK/conf"
mcopy -o -i "$WORK/boot.img@@$PART" "$WORK/conf" ::zig-metal-unikernel.conf ||
    { echo "could not write zig-metal-unikernel.conf"; exit 2; }
TRANSPORT=pci VOLUME="$WORK/vol.img" PEER_REQUEST="$HERE/requests/trickle-chunked-long.http" \
    PEER_MSS=16 PEER_DRIP_US=5000000 \
    timeout 300 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
code=$?
line=$(grep -E '^peer( 1)?: ' "$WORK/out" | head -1)
grep -Eq '^peer( 1)?: 408' <<< "$line" ||
    fail "slow body past the rule's deadline: not a 408 (exit $code): $line"
[ "$failed" = 0 ] && echo "      a trickled body: the caller beside it answered at once, and one past the deadline a 408"
[ "$before" = 0 ] || failed=1

# A slow uploader (QUEUE 169). Derived, not yet run on a guest when written
# (CC's container has no KVM).
before=$failed; failed=0
{ printf 'POST /login/full HTTP/1.1\r\nHost: lynrummy.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 64000\r\nConnection: close\r\n\r\nname=x&password='
  head -c 63984 /dev/zero | tr '\0' 'a'; } > "$WORK/slow-form.http"
cp "$SITE" "$WORK/boot.img"; cp "$SITE" "$WORK/vol.img"
printf 'requests = 2\n' > "$WORK/conf"
mcopy -o -i "$WORK/boot.img@@$PART" "$WORK/conf" ::zig-metal-unikernel.conf ||
    { echo "could not write zig-metal-unikernel.conf"; exit 2; }
TRANSPORT=pci PEER_CLIENTS=2 PEER_CLIENT_GAP_US=300000 VOLUME="$WORK/vol.img" \
    PEER_REQUEST="$WORK/slow-form.http,$HERE/requests/shapes/home.http" \
    PEER_MSS=1460 PEER_DRIP_US=22000 \
    timeout 300 "$VMM" "$KERNEL" "$WORK/boot.img" "" / > "$WORK/out" 2> "$WORK/err"
code=$?
slow=$(grep '^peer 1: ' "$WORK/out")
caller=$(grep '^peer 2: ' "$WORK/out")
if [ "$code" != 0 ] || ! grep -q '^  served 2 request(s)' "$WORK/out"; then
    fail "slow uploader: the guest did not serve its two requests and stop (exit $code): $(tail -1 "$WORK/err")"
else
    c_open=$(us_of "$caller" opened); c_answered=$(us_of "$caller" answered)
    s_answered=$(us_of "$slow" answered)
    { [ -n "$c_answered" ] && grep -q '^peer 2: 200,' <<< "$caller" && [ $(( c_answered - c_open )) -lt 100000 ]; } ||
        fail "slow uploader: the caller beside a 64 KB/s body was not answered within 100 ms: $caller"
    { [ -n "$s_answered" ] && ! grep -q '^peer 1: 408,' <<< "$slow" && [ -n "$c_answered" ] && [ "$c_answered" -lt "$s_answered" ]; } ||
        fail "slow uploader: the slow body was not answered by its route after the caller: $slow | $caller"
    grep -q '^    body: 64000 bytes, arrived in ' "$WORK/out" ||
        fail "slow uploader: the log does not say the body's size and arrival time"
fi
[ "$failed" = 0 ] && echo "      a 64 KB/s body: the caller beside it answered at once"
[ "$before" = 0 ] || failed=1

[ "$failed" = 0 ] && echo "PASS  timeouts: a silent client, a stalled reader and a slow body hold nobody up, and are let go when the rule says"
exit "$failed"
