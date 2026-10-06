#!/bin/bash
# **THE DURABILITY SWEEP'S OWN TEST** (QUEUE item 70), without a guest:
# sweep.sh with POST drives a fake metal-vmm whose volume is a text file, a
# post writes the message to it or not as each seed is told, and a read-back
# boot pages out whatever the volume holds. Its verdicts are checked against
# what each seed was told to do.
#
#   ./sweep_durable_test.sh   # needs zig-coverage-sdk's tools/report.py
#                             # (a sibling checkout, or COVERAGE_SDK=<dir>)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
expect() { # expect <what> <pattern> <text>
  if ! grep -q -- "$2" <<< "$3"; then echo "FAIL: $1: no \"$2\" in:"; echo "$3" | sed 's/^/    /'; fail=1; fi
}

printf 'pristine disk' > "$T/site.img"
printf 'conversation:\n' > "$T/volume.img"
printf 'POST /chat HTTP/1.1\r\n\r\nhello from the sweep' > "$T/post.req"
: > "$T/kernel.elf"

# **THE FAKE MACHINE.** A post (PEER_REQUEST set) is told 303 and appends
# the message to VOLUME, unless its seed says otherwise; a read-back (no
# PEER_REQUEST) pages out the volume. What each seed does:
#   unhurt  303, kept
#   1       303, kept: ok, kept
#   2       303, lost, nothing to excuse it: FAIL
#   3       303, lost, VOLUME_CACHE=lie: allowed
#   4       no answer, not kept: ok, not told, not kept
#   5       303, lost, VOLUME_SYNC_FAIL: allowed
#   6       303, and the volume left unreadable: the read-back gets no page
#   7       no answer, but kept: ok, not told, kept
cat > "$T/vmm" <<'EOF'
#!/bin/bash
s="${FAULT_SEED:-}"
if [ -z "${PEER_REQUEST:-}" ]; then
  if grep -q UNREADABLE "$VOLUME"; then echo "peer: 500"; : > "$PEER_BODY"; exit 0; fi
  echo "peer: 200 \"$(head -c 20 "$VOLUME")\""
  cp "$VOLUME" "$PEER_BODY"
  exit 0
fi
[ "$VOLUME_CUT_AT_EXIT" = 1 ] || { echo "no VOLUME_CUT_AT_EXIT" >&2; exit 3; }
knobs="none"
case "$s" in 3) knobs="VOLUME_CACHE=lie" ;; 5) knobs="VOLUME_CACHE=1 VOLUME_SYNC_FAIL=2" ;; "") ;; *) knobs="WIRE_EAT=$s" ;; esac
[ -n "$s" ] && echo "metal-vmm: FAULT_SEED=$s is $knobs" >&2
echo "{\"metal_vmm_run\":{\"seed\":${s:-null},\"knobs\":\"$knobs\"}}" >> "$COVERAGE_OUT"
echo '{"antithesis_sdk":{"language":{"name":"Zig","version":"0.16.0"},"sdk_version":"0.0.1","protocol_version":"1.1.0"}}' >> "$COVERAGE_OUT"
status=303
case "$s" in
  2 | 3 | 5) ;;
  4) status=0 ;;
  6) echo UNREADABLE >> "$VOLUME" ;;
  7) status=0; tail -c 20 "$PEER_REQUEST" >> "$VOLUME" ;;
  *) tail -c 20 "$PEER_REQUEST" >> "$VOLUME" ;;
esac
: > "$PEER_BODY"
[ "$status" = 0 ] || echo "peer: $status \"\""
exit 0
EOF
cat > "$T/sound" <<'EOF'
#!/bin/bash
echo "  sound"
EOF
chmod +x "$T/vmm" "$T/sound"
REPORT="${COVERAGE_SDK:-$HERE/../zig-coverage-sdk}/tools/report.py"
[ -f "$REPORT" ] || { echo "no $REPORT: set COVERAGE_SDK"; exit 1; }

run_sweep() {
  VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" VOLUME_SITE="$T/volume.img" \
    POST="$T/post.req" READ_BACK=/chat/recent MARK="hello from the sweep" "$HERE/sweep.sh" "$@" 2>&1
}
out=$(run_sweep 1 7)
code=$?
first="$out"

expect "the mode is said" 'durability: each seed posts .*post.req, then reads back /chat/recent' "$out"
expect "seed 1" '^1 .* ok, kept ' "$out"
expect "seed 2" '^2 .*FAIL: told 303 and the message is not on the volume' "$out"
expect "seed 3" '^3 .*lost (allowed: VOLUME_CACHE=lie)' "$out"
expect "seed 4" '^4 .*ok, not told, not kept' "$out"
expect "seed 5" '^5 .*lost (allowed: VOLUME_SYNC_FAIL)' "$out"
expect "seed 6" '^6 .*FAIL: the read-back boot got no page (status 500)' "$out"
expect "seed 7" '^7 .*ok, not told, kept' "$out"
expect "the summary" '^7 seeds: 3 ok, 2 lost as their faults allow, 2 failed' "$out"
expect "how to repeat it" 'repeat it: WIRE_EAT=2 PEER_REQUEST=.*post.req VOLUME=<a copy of .*volume.img> VOLUME_CUT_AT_EXIT=1' "$out"
[ $code = 1 ] || { echo "FAIL: sweep.sh exited $code, not 1"; fail=1; }

# Nothing can be judged when the pristine volume already holds the message.
printf 'conversation:\nhello from the sweep\n' > "$T/volume.img"
out=$(run_sweep 1 1)
code=$?
expect "a volume that already holds it" 'the pristine volume already holds MARK: nothing can be judged' "$out"
[ $code = 2 ] || { echo "FAIL: a judged-nothing sweep exited $code, not 2"; fail=1; }

# Nor without what a durability sweep needs.
out=$(VMM="$T/vmm" KERNEL="$T/kernel.elf" SITE="$T/site.img" POST="$T/post.req" "$HERE/sweep.sh" 1 1 2>&1)
expect "POST alone" 'POST needs READ_BACK=<path> and MARK=<text>' "$out"

[ -z "${SHOW:-}" ] || echo "$first"
if [ $fail = 0 ]; then echo "sweep_durable_test: every verdict and the summary as told"; fi
exit $fail
