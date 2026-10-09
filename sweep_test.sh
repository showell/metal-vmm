#!/bin/bash
# **THE SWEEP'S OWN TEST**, without a guest: sweep.sh drives a fake metal-vmm
# whose every seed is a run told in advance, and a fake sound.sh, and its
# verdicts and summary are checked against what each seed was told to do.
#
#   ./sweep_test.sh           # needs zig-coverage-sdk's tools/report.py
#                             # (a sibling checkout, or COVERAGE_SDK=<dir>)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
expect() { # expect <what> <pattern> <text>
  if ! grep -q -- "$2" <<< "$3"; then echo "FAIL: $1: no \"$2\" in:"; echo "$3" | sed 's/^/    /'; fail=1; fi
}

# A volume, and a kernel that is only a name here.
printf 'pristine volume' > "$T/site.img"
: > "$T/kernel.elf"

# **THE FAKE MACHINE.** Its arguments are metal-vmm's; what each seed does:
#   unhurt  the page "hello"
#   1       the same page, nothing written: ok
#   2       a page that differs, with no excuse: FAIL
#   3       a reset, and no page: allowed
#   4       the guest writes, and leaves the volume unsound: FAIL
#   5       exit 1 (stuck): FAIL
#   6       a coverage property broken: FAIL
#   7       the guest writes a sound volume, and the page: ok
#   8       a lossy wire, and the peer gives up: no page, allowed
#   10      a page cut short, which the guest says its stop cut: allowed
#   11      another status, whole, and the guest's stop cut a response too:
#           FAIL (a stop cuts a page short; it does not change its status)
#   12      a disk refusal answered with another status (404): FAIL
#   13      a reset answered with another page under the same status: FAIL
#   16      a reset before the request was whole, then an idle end (exit 1): allowed
#   17      an idle end (exit 1) with no client that left: FAIL
#   14      a disk refusal answered 500: allowed (the server says it failed)
#   15      a peer's reset answered 500: FAIL (only a disk fault excuses a 5xx)
#   18      no answer, another client answered and the guest served its
#           limit of 1: allowed (the request limit went to another client)
#   19      no answer, the limit served, no other client answered: FAIL
#   23      a disk that lied about its cache, cut mid-write, left unsound:
#           allowed (Steve, 2026-10-09)
#   24      the same lie, no cut, unsound: FAIL (a lie alone loses nothing)
#   25      the lie and the cut, unsound, and another page: FAIL (a lie
#           excuses the disk, never the page)
#   26      the lie and the cut, unsound, and the cut lost nothing the
#           cache held: FAIL (the lie cost nothing, so the damage is the
#           guest's; metal-vmm QUEUE 122)
#   27      no answer, the limit of 2 served, another client answered
#           once: FAIL (one request served was this client's, and its
#           answer lost; QUEUE 122)
#   28      a reset drawn that never came, and no page: FAIL (an excuse needs
#           its fault to have fired; metal-vmm QUEUE 124(e))
#   29      a disk refusal drawn that never came, answered 500: FAIL
#   9       a 200 whose page metal-vmm did not write (an answer kept only in
#           part): FAIL, never a match of two empty pages
# A run with PEER_REQUEST (a shape's) and no seed above has for its page the
# request file's own bytes, so each shape's page is its own.
# With FAKE_UNHURT_NO_PAGE set, the unhurt run's page is not written either.
cat > "$T/vmm" <<'EOF'
#!/bin/bash
img="$2"
s="${FAULT_SEED:-}"
L='"location":{"class":"tcp","function":"f","file":"tcp.zig","begin_line":1,"begin_column":1}'
ev() { echo "{\"antithesis_assert\":{\"hit\":$3,\"must_hit\":true,\"assert_type\":\"x\",\"display_type\":\"$1\",\"message\":\"$2\",\"condition\":$4,\"id\":\"$2\",$L}}" >> "$COVERAGE_OUT"; }
knobs="none"
case "$s" in 23 | 25 | 26) knobs="DISK_CACHE=lie DISK_CUT_AFTER=2" ;; 27) knobs="WIRE_EAT=3" ;; 28) knobs="PEER_RESET_AT=500" ;; 29) knobs="DISK_REFUSE=4" ;; 24) knobs="DISK_CACHE=lie" ;; 18 | 19) knobs="WIRE_EAT=3" ;; 16) knobs="PEER_RESET_AT=500" ;; 17) knobs="WIRE_EAT=17" ;; 3) knobs="PEER_RESET_AT=500" ;; 12) knobs="DISK_REFUSE=4" ;; 13) knobs="PEER_RESET_AT=500" ;; 14) knobs="DISK_REFUSE=4" ;; 15) knobs="PEER_RESET_AT=500" ;; 4) knobs="DISK_WRITES_ONLY=1" ;; "") ;; *) knobs="WIRE_EAT=$s" ;; esac
[ -n "$s" ] && echo "metal-vmm: FAULT_SEED=$s is $knobs" >&2
# What fired, as metal-vmm says it (reports.zig `fired`): every fault the
# seed drew, but for 28 and 29, whose faults never came.
fired=""; turned=""
for k in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT DISK_BAD_SECTOR VOLUME_CUT_AFTER VOLUME_SHORT_AT VOLUME_GONE_AT VOLUME_READ_ONLY_AT VOLUME_SYNC_FAIL; do
  case " $knobs" in *" $k="*) turned=1; case "$s" in 28 | 29) ;; *) fired="$fired $k" ;; esac ;; esac
done
[ -z "$turned" ] || echo "metal-vmm: fired:${fired:- none}" >&2
echo "{\"metal_vmm_run\":{\"seed\":${s:-null},\"knobs\":\"$knobs\"}}" >> "$COVERAGE_OUT"
echo '{"antithesis_sdk":{"language":{"name":"Zig","version":"0.16.0"},"sdk_version":"0.0.1","protocol_version":"1.1.0"}}' >> "$COVERAGE_OUT"
ev Sometimes "tcp: common" true true
broken=0
page="hello"; status=200; code=0
case "$s" in
  2) page="something else" ;;
  3) page=""; status=0 ;;
  4) printf 'UNSOUND' > "$img" ;;
  5) code=1 ;;
  6) ev Always "tcp: an always" true false; broken=1 ;;
  7) printf 'sound, written' > "$img"; ev Sometimes "tcp: only seed 7" true true ;;
  8) page=""; status=0; echo "metal-vmm: the first client gave up: it sent the same thing too often, unanswered" >&2 ;;
  10) page="hel"; echo "  let go at the end: 1 response(s) cut by the stop, 2 bytes never acknowledged" ;;
  12) page="not found"; status=404 ;;
  13) page="jello" ;;
  16 | 17) page=""; status=0; code=1; echo "error: GuestIdle" >&2 ;;
  14) page="Home unavailable"; status=500 ;;
  15) page="Home unavailable"; status=500 ;;
  18) page=""; status=0; echo "  serving 1 request(s), as gopher-metal.conf says"; echo "  served 1 request(s); base heap holds 52 live bytes"; echo "peer 2: 204, 1 of 1 answers, 65 bytes, done" ;;
  19) page=""; status=0; echo "  serving 1 request(s), as gopher-metal.conf says"; echo "  served 1 request(s); base heap holds 52 live bytes"; echo "peer 2: 0, 0 of 1 answers, 0 bytes, established" ;;
  23 | 24 | 25 | 26) printf 'UNSOUND' > "$img"; [ "$s" = 24 ] || echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2; [ "$s" != 25 ] || page="jello"
    lost=3; [ "$s" != 26 ] || lost=0
    [ "$s" = 24 ] || echo "metal-vmm: disk: a write cache, write-back, though the guest did not negotiate FLUSH (DISK_CACHE=lie); 4 writes held, 0 flushes; the power cut lost $lost sectors never flushed" >&2 ;;
  28) page=""; status=0 ;;
  29) page="Home unavailable"; status=500 ;;
  27) page=""; status=0; echo "  serving 2 request(s), as gopher-metal.conf says"; echo "  served 2 request(s); base heap holds 52 live bytes"; echo "peer 2: 204, 1 of 1 answers, 65 bytes, done" ;;
  11) page="oops"; status=500; echo "  let go at the end: 1 response(s) cut by the stop, 2 bytes never acknowledged" ;;
esac
case "$s" in [2-9] | 1[0-9] | 2[3-9]) ;; *) [ -z "${PEER_REQUEST:-}" ] || page="$(cat "${PEER_REQUEST%%,*}")" ;; esac
# A request that is only "fail500" is answered 500: a shape gone stale.
[ "$page" != "fail500" ] || status=500
if [ "$s" = 9 ] || { [ -z "$s" ] && [ -n "${FAKE_UNHURT_NO_PAGE:-}" ]; }; then
  echo "metal-vmm: the answer was 70000 bytes and the client keeps 65536; PEER_BODY and PEER_RESPONSE are not written" >&2
else
  printf '%s' "$page" > "$PEER_BODY"
fi
# The wire's account of the peer's frames, on stderr as metal-vmm prints it
# whenever the peer can lose one: it is not the status.
echo "peer: 51 frames sent, 1 lost (#3), 6309 ms of the guest's time" >&2
echo "peer: $status \"$page\""
[ -n "${FAKE_NO_COVERAGE:-}" ] || echo "metal-vmm: coverage: 1 of 1 properties reached (1 hold, $broken broken), from 3 lines over 1 boots" >&2
exit $code
EOF
cat > "$T/sound" <<'EOF'
#!/bin/bash
if grep -q UNSOUND "$1"; then echo "  1 complaint"; exit 1; fi
echo "  sound"
EOF
chmod +x "$T/vmm" "$T/sound"
REPORT="${COVERAGE_SDK:-$HERE/../zig-coverage-sdk}/tools/report.py"
[ -f "$REPORT" ] || { echo "no $REPORT: set COVERAGE_SDK"; exit 1; }

out=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 8 2>&1)
code=$?

expect "the unhurt run" '^unhurt: exit 0, status 200, 5 bytes of /' "$out"
expect "seed 1" '^1 .* ok  *WIRE_EAT=1$' "$out"
expect "seed 2" '^2 .*FAIL: not the page (status 200)' "$out"
expect "seed 3" '^3 .*differs (allowed: PEER_RESET_AT)' "$out"
expect "seed 4" '^4 .*FAIL: the volume is not sound' "$out"
expect "seed 5" '^5 .*FAIL: exit 1 (unhurt: 0)' "$out"
expect "seed 6" '^6 .*FAIL: 1 coverage properties broken' "$out"
expect "seed 7" '^7 .* ok ' "$out"
expect "seed 8" '^8 .*differs (allowed: the peer gave up)' "$out"
expect "the coverage report" '^FAIL  *Always  *tcp: an always' "$out"
expect "how many runs reached it" 'tcp: common  (tcp.zig:1; reached by 9 of 9 runs, first a run with no faults' "$out"
expect "a rare property" 'tcp: only seed 7  (FAULT_SEED=7)' "$out"
expect "the summary" '^8 seeds: 2 ok, 2 differ as their faults allow, 4 failed' "$out"
expect "a failing seed, as knobs" 'FAULT_SEED=4: FAIL: the volume is not sound' "$out"
expect "how to repeat it" 'repeat it: DISK_WRITES_ONLY=1 TRANSPORT=pci' "$out"
[ $code = 1 ] || { echo "FAIL: sweep.sh exited $code, not 1"; fail=1; }

# A sweep of only good seeds, with a floor it meets, passes.
printf 'tcp: common\n' > "$T/floor"
good=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" FLOOR="$T/floor" "$HERE/sweep.sh" 7 7 2>&1)
[ $? = 0 ] || { echo "FAIL: a clean sweep did not pass:"; echo "$good" | sed 's/^/    /'; fail=1; }
expect "a clean sweep's floor" '^2 runs, 2 properties, 1 on the floor' "$good"
if grep -q "under the floor" <<< "$good"; then echo "FAIL: a clean sweep is under its floor"; fail=1; fi

# A failing seed's files are kept when asked (KEEP_FAILED), and only its.
kept="$T/kept"
KEEP_FAILED="$kept" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 2 > /dev/null 2>&1
[ -f "$kept/seed2/seed2.out" ] && [ -f "$kept/seed2/seed2.err" ] || { echo "FAIL: seed 2's stdout and stderr were not kept"; fail=1; }
[ ! -e "$kept/seed1" ] || { echo "FAIL: seed 1 passed and was kept"; fail=1; }

# A seed whose page was not written fails; it is not an empty page that
# matches.
nopage=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 9 9 2>&1)
[ $? = 1 ] || { echo "FAIL: a seed with no page written did not fail the sweep"; fail=1; }
expect "seed 9" '^9 .*none .*FAIL: not the page (status 200)' "$nopage"

# A page the guest says its stop cut differs as allowed.
cut=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 10 10 2>&1)
expect "seed 10" '^10 .*differs (allowed: the stop cut it)' "$cut"
# The stop excuses a page cut short, not another status (QUEUE 103).
other=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 11 11 2>&1)
expect "seed 11" '^11 .*FAIL: not the page (status 500)' "$other"

# A fault excuses no answer, or a page cut short; never another status, nor
# another page under the same one.
other=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 12 13 2>&1)
expect "seed 12" '^12 .*FAIL: not the page (status 404)' "$other"
expect "seed 13" '^13 .*FAIL: not the page (status 200)' "$other"
idle=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 16 17 2>&1)
expect "seed 16" '^16 .*differs (allowed: an idle end after the client left' "$idle"
expect "seed 17" '^17 .*FAIL: exit 1 (unhurt: 0)' "$idle"
five=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 14 15 2>&1)
expect "seed 14" '^14 .*differs (allowed: DISK_REFUSE (a 500))' "$five"
expect "seed 15" '^15 .*FAIL: not the page (status 500)' "$five"

limit=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 18 19 2>&1)
expect "seed 18" '^18 .*differs (allowed: the request limit went to another client)' "$limit"
expect "seed 19" '^19 .*FAIL: not the page (status 0)' "$limit"

lied=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 23 26 2>&1)
expect "seed 23" '^23 .*differs (allowed: DISK_CACHE=lie (the volume left unsound))' "$lied"
expect "seed 24" '^24 .*FAIL: the volume is not sound' "$lied"
expect "seed 25" '^25 .*FAIL: not the page (status 200)' "$lied"
expect "seed 26" '^26 .*FAIL: the volume is not sound' "$lied"
limit2=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 27 27 2>&1)
unfired=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 28 29 2>&1)
expect "seed 28" '^28 .*FAIL: not the page (status 0)' "$unfired"
expect "seed 29" '^29 .*FAIL: not the page (status 500)' "$unfired"
expect "seed 27" '^27 .*FAIL: not the page (status 0)' "$limit2"

# A kernel that reports no property (built without -Dcoverage) stops the
# sweep before any seed: it would judge none.
silent=$(FAKE_NO_COVERAGE=1 VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 1 2>&1)
[ $? = 2 ] || { echo "FAIL: a kernel that reports no property did not stop the sweep with 2"; fail=1; }
expect "a kernel without its coverage" 'reported no coverage property in its unhurt run' "$silent"
if grep -q '^1 ' <<< "$silent"; then echo "FAIL: a seed ran on a kernel that reports no property"; fail=1; fi

# An unhurt run with no page leaves nothing to judge: the sweep stops, 2.
nothing=$(FAKE_UNHURT_NO_PAGE=1 VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 1 2>&1)
[ $? = 2 ] || { echo "FAIL: an unhurt run with no page did not stop the sweep with 2"; fail=1; }
expect "the unhurt run with no page" 'status 200 and no page (exit 0): nothing can be judged' "$nothing"

# **SHAPES**: seed s sends shape (s mod n) and is judged against that
# shape's own unhurt run (20 is "a", 21 is "b", each page its own); the
# setup's requests go first; an unhurt answer not the shape's EXPECT stops
# the sweep with 2.
mkdir -p "$T/shapes"
printf 'page a' > "$T/shapes/a.http"
printf 'page b' > "$T/shapes/b.http"
printf '# a\nPEER_REQUEST=a.http\nEXPECT=200\n' > "$T/shapes/a.shape"
printf 'PEER_REQUEST=b.http  # b\nEXPECT=200\n' > "$T/shapes/b.shape"
printf 'a.http\n' > "$T/shapes/setup"
shaped=$(SHAPES="$T/shapes" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 20 21 2>&1)
[ $? = 0 ] || { echo "FAIL: a sweep of two shapes did not pass:"; echo "$shaped" | sed 's/^/    /'; fail=1; }
expect "the setup" '^setup: a.http, status 200' "$shaped"
expect "shape a's unhurt run" '^shape a: unhurt status 200, 6 bytes' "$shaped"
expect "seed 20, shape a" '^20 *a .* ok ' "$shaped"
expect "seed 21, shape b" '^21 *b .* ok ' "$shaped"
printf 'PEER_REQUEST=b.http\nEXPECT=404\n' > "$T/shapes/b.shape"
SHAPES="$T/shapes" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 20 21 > "$T/expect.out" 2>&1
[ $? = 2 ] || { echo "FAIL: a shape whose unhurt run is not its EXPECT did not stop the sweep with 2"; fail=1; }
expect "the shape not as expected" 'shape b: its unhurt run answered 200, not 404: nothing can be judged' "$(cat "$T/expect.out")"

# A shape with no EXPECT has no answer it is held to: one gone stale (here
# a 500) would be every seed's "ok". The sweep stops, 2 (QUEUE 122).
mkdir -p "$T/stale"
printf 'page a' > "$T/stale/a.http"
printf 'fail500' > "$T/stale/c.http"
printf 'PEER_REQUEST=a.http\nEXPECT=200\n' > "$T/stale/a.shape"
printf 'PEER_REQUEST=c.http\n' > "$T/stale/c.shape"
SHAPES="$T/stale" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 20 21 > "$T/stale.out" 2>&1
[ $? = 2 ] || { echo "FAIL: a shape with no EXPECT did not stop the sweep with 2:"; sed 's/^/    /' "$T/stale.out"; fail=1; }
expect "the shape with no EXPECT" 'shape c: no EXPECT' "$(cat "$T/stale.out")"

if [ $fail = 0 ]; then echo "sweep_test: every verdict and the summary as told"; fi
exit $fail
