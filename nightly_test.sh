#!/bin/bash
# **THE NIGHT'S OWN TEST**, without a guest (metal-vmm QUEUE 124(d)):
# nightly.sh runs one batch of sweep.sh over a fake metal-vmm, in the
# foreground, and what it writes is checked: a report-only failure (a run
# that reported no property, SILENT) must reach failures.log and the
# progress line, not read as a clean batch.
#
#   ./nightly_test.sh         # needs zig-coverage-sdk's tools/report.py
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="${NIGHTLY_TEST_DIR:-$(mktemp -d)}" # NIGHTLY_TEST_DIR keeps what it wrote
[ -n "${NIGHTLY_TEST_DIR:-}" ] || trap 'rm -rf "$T"' EXIT
fail=0
expect() { # expect <what> <pattern> <text>
  if ! grep -q -- "$2" <<< "$3"; then echo "FAIL: $1: no \"$2\" in:"; echo "$3" | sed 's/^/    /'; fail=1; fi
}
printf 'pristine volume' > "$T/site.img"
: > "$T/kernel.elf"
# Every run the page "hello", unhurt, with one property; seed 2 reports none.
cat > "$T/vmm" <<'EOF'
#!/bin/bash
s="${FAULT_SEED:-}"
[ -n "$s" ] && echo "metal-vmm: FAULT_SEED=$s is none" >&2
echo "{\"metal_vmm_run\":{\"seed\":${s:-null},\"knobs\":\"none\"}}" >> "$COVERAGE_OUT"
echo '{"antithesis_sdk":{"language":{"name":"Zig","version":"0.16.0"},"sdk_version":"0.0.1","protocol_version":"1.1.0"}}' >> "$COVERAGE_OUT"
if [ "$s" != 2 ]; then
  echo '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"x","display_type":"Sometimes","message":"tcp: common","condition":true,"id":"tcp: common","location":{"class":"tcp","function":"f","file":"tcp.zig","begin_line":1,"begin_column":1}}}' >> "$COVERAGE_OUT"
  echo "metal-vmm: coverage: 1 of 1 properties reached (1 hold, 0 broken), from 2 lines over 1 boots" >&2
fi
printf 'hello' > "$PEER_BODY"
echo 'peer: 200 "hello"'
exit 0
EOF
chmod +x "$T/vmm"
SDK="${COVERAGE_SDK:-$HERE/../zig-coverage-sdk}"
[ -f "$SDK/tools/report.py" ] || { echo "no $SDK/tools/report.py: set COVERAGE_SDK"; exit 1; }
NIGHTLY_ATTACHED=1 NIGHTLY_OUT="$T/out" NIGHTLY_ROOT="$T/root" HOURS=0.001 FIRST=1 BATCH=3 \
  VMM_BIN="$T/vmm" KERNEL_ELF="$T/kernel.elf" SITE="$T/site.img" COVERAGE_SDK="$SDK" GOPHER="$HERE" \
  "$HERE/nightly.sh" > "$T/nightly.out" 2>&1
failures=$(cat "$T/out/failures.log" 2>/dev/null)
progress=$(cat "$T/out/progress.log" 2>/dev/null)
expect "the SILENT line in failures.log" 'batch 1-3: SILENT FAULT_SEED=2' "$failures"
expect "the batch's report failure in progress.log" '1-3 .* report failed' "$progress"
expect "the night's report failures in DONE" 'report failed in 1 batch' "$(cat "$T/out/DONE" 2>/dev/null)"
if [ $fail = 0 ]; then echo "nightly_test: a report-only failure is said where a night is read"; fi
exit $fail
