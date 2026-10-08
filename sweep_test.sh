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
#   9       a 200 whose page metal-vmm did not write (an answer kept only in
#           part): FAIL, never a match of two empty pages
# With FAKE_UNHURT_NO_PAGE set, the unhurt run's page is not written either.
cat > "$T/vmm" <<'EOF'
#!/bin/bash
img="$2"
s="${FAULT_SEED:-}"
L='"location":{"class":"tcp","function":"f","file":"tcp.zig","begin_line":1,"begin_column":1}'
ev() { echo "{\"antithesis_assert\":{\"hit\":$3,\"must_hit\":true,\"assert_type\":\"x\",\"display_type\":\"$1\",\"message\":\"$2\",\"condition\":$4,\"id\":\"$2\",$L}}" >> "$COVERAGE_OUT"; }
knobs="none"
case "$s" in 3) knobs="PEER_RESET_AT=500" ;; 4) knobs="DISK_WRITES_ONLY=1" ;; "") ;; *) knobs="WIRE_EAT=$s" ;; esac
[ -n "$s" ] && echo "metal-vmm: FAULT_SEED=$s is $knobs" >&2
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
  11) page="oops"; status=500; echo "  let go at the end: 1 response(s) cut by the stop, 2 bytes never acknowledged" ;;
esac
if [ "$s" = 9 ] || { [ -z "$s" ] && [ -n "${FAKE_UNHURT_NO_PAGE:-}" ]; }; then
  echo "metal-vmm: the answer was 70000 bytes and the client keeps 65536; PEER_BODY and PEER_RESPONSE are not written" >&2
else
  printf '%s' "$page" > "$PEER_BODY"
fi
# The wire's account of the peer's frames comes first, as metal-vmm prints
# it whenever the peer can lose one: it is not the status.
echo "peer: 51 frames sent, 1 lost (#3), 6309 ms of the guest's time"
echo "peer: $status \"$page\""
echo "metal-vmm: coverage: 1 of 1 properties reached (1 hold, $broken broken), from 3 lines over 1 boots" >&2
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

# An unhurt run with no page leaves nothing to judge: the sweep stops, 2.
nothing=$(FAKE_UNHURT_NO_PAGE=1 VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 1 2>&1)
[ $? = 2 ] || { echo "FAIL: an unhurt run with no page did not stop the sweep with 2"; fail=1; }
expect "the unhurt run with no page" 'status 200 and no page (exit 0): nothing can be judged' "$nothing"

if [ $fail = 0 ]; then echo "sweep_test: every verdict and the summary as told"; fi
exit $fail
