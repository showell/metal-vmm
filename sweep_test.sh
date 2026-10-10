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
#   58      a volume refusal that fired only at boot, before the client
#           opened, answered 500: FAIL (a 5xx is excused only by a fault
#           that fired during that client's request; metal-vmm QUEUE 138(d))
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
#   30      no answer: the guest let this client go unheard, and that let-go
#           counts in its "served", which with another client's answer makes
#           its limit of 2: FAIL (a let-go is no request the limit went to;
#           metal-vmm QUEUE 124(a))
#   31      a cut, and a volume fsck calls sound but for what a stop leaves,
#           whose stop lost a file the request does not touch: FAIL
#           (metal-vmm QUEUE 124(b))
#   32      the same cut and leftovers, every untouched file there: ok
#   33      the boot disk's power cut, and the attached volume holding what a
#           stop leaves: ok (one power stops the whole machine; QUEUE 124(c))
#   34-36   a durable shape's write (QUEUE 125): its request "WRITE" appends
#           "written" to the volume and is answered 200, and its read-back
#           ("READBACK") pages out the volume. 34 keeps it: ok. 35 is told
#           200 and keeps nothing: FAIL. 36 keeps nothing behind a lying
#           cache whose power failed with writes held: allowed.
#   46-48   a durable shape whose read-back ("READBACK404") is a 404 when
#           nothing was written, as `GET /game/sessions/2/actions` is
#           (QUEUE 127(c)), and a 500 when the volume holds "CORRUPT".
#           46: a reset and no answer, nothing written, the read-back a
#           404 as the pristine volume's: allowed, not told. 47: told 200, nothing written,
#           a 404 as the pristine volume's, so the write is not on the
#           volume (250cc5d): FAIL. 48: told 200, a lying cache lost what it held and
#           left the volume so the read-back is a 500: allowed (127(f)).
#   53-55   the kernel's "no damage" property broken (QUEUE 128). 53: by a
#           DISK_ROT that fired: allowed. 54: the same, and another property
#           broken too: FAIL. 55: DISK_ROT drawn, never fired: FAIL.
#   9       a 200 whose page metal-vmm did not write (an answer kept only in
#           part): FAIL, never a match of two empty pages
#   38-45   two clients (QUEUE 126), each paged its own request file, client
#           k's page at <PEER_BODY>.k and its status on its "peer k:" line.
#           Shape p asks at once, shape q in turn (PEER_IN_TURN=1). As
#           the site's own limit of 1 does on a guest, a boot disk that
#           sweep.sh did not raise (no "REQUESTS=") serves client 1 alone
#           (QUEUE 127(h)).
#           38 (p): client 2's page differs, nothing to excuse it: FAIL.
#           39 (q): client 1 reset (PEER_RESET_AT) and no answer, client 2
#           answered 404: allowed, client 2 asked after client 1 differed.
#           40 (p): client 2 no answer, client 1 vanished
#           (PEER_VANISH_AFTER, fired): allowed, as a client that vanished
#           holds the guest's one connection.
#           41 (q): client 1's page as unhurt, client 2 404: FAIL (request 1
#           damaged request 2).
#           42 (p): client 1 reset, client 2 404: FAIL (not in turn: client
#           2 depends on nothing).
#           43 (q), 44 (p): both pages as unhurt: ok.
#           45 (q): client 2 a 500, a disk refusal fired: allowed.
#           50 (p): client 1 reset, client 2 no answer: FAIL (a reset frees
#           the guest at once; QUEUE 127(e)).
#           51 (q): client 1 reset and no answer, client 2 a 500, no disk
#           fault: FAIL (after an earlier client differed, only what UNMADE
#           names or the client's own excuses; QUEUE 127(d)).
#           57 (q): client 1's page cut short under its own status (the stop
#           cut it), client 2 404: FAIL (a page cut short says client 1's
#           write was made; UNMADE is no excuse; QUEUE 134(g)).
#           52: a cut, and a volume fsck calls sound (no leftovers) that lost
#           a file the request does not touch: FAIL (QUEUE 127, lesser).
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
case "$s" in 23 | 25 | 26) knobs="DISK_CACHE=lie DISK_CUT_AFTER=2" ;; 27) knobs="WIRE_EAT=3" ;; 28) knobs="PEER_RESET_AT=500" ;; 29) knobs="DISK_REFUSE=4" ;; 30) knobs="WIRE_EAT=3" ;; 31 | 32 | 33) knobs="DISK_CUT_AFTER=2" ;; 36 | 48) knobs="VOLUME_CACHE=lie" ;; 46) knobs="PEER_RESET_AT=500" ;; 39 | 42 | 50 | 51) knobs="PEER_RESET_AT=500" ;; 40) knobs="PEER_VANISH_AFTER=3" ;; 53 | 54 | 55) knobs="DISK_ROT=4093,20" ;; 52) knobs="DISK_CUT_AFTER=2" ;; 45) knobs="DISK_REFUSE=4" ;; 58) knobs="VOLUME_READ_ONLY_AT=3" ;; 24) knobs="DISK_CACHE=lie" ;; 18 | 19) knobs="WIRE_EAT=3" ;; 16) knobs="PEER_RESET_AT=500" ;; 17) knobs="WIRE_EAT=17" ;; 3) knobs="PEER_RESET_AT=500" ;; 12) knobs="DISK_REFUSE=4" ;; 13) knobs="PEER_RESET_AT=500" ;; 14) knobs="DISK_REFUSE=4" ;; 15) knobs="PEER_RESET_AT=500" ;; 4) knobs="DISK_WRITES_ONLY=1" ;; "") ;; *) knobs="WIRE_EAT=$s" ;; esac
[ -n "$s" ] && echo "metal-vmm: FAULT_SEED=$s is $knobs" >&2
# What fired, as metal-vmm says it (reports.zig `fired`): every fault the
# seed drew, but for 28 and 29, whose faults never came.
fired=""; turned=""
for k in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT DISK_BAD_SECTOR VOLUME_CUT_AFTER VOLUME_SHORT_AT VOLUME_GONE_AT VOLUME_READ_ONLY_AT VOLUME_SYNC_FAIL; do
  case " $knobs" in *" $k="*) turned=1; case "$s" in 28 | 29 | 55) ;; *) fired="$fired $k" ;; esac ;; esac
done
[ -z "$turned" ] || echo "metal-vmm: fired:${fired:- none}" >&2
# And which fired while a client's request was open (reports.zig
# `During`): 14's refusal during client 1's, 45's during client 2's; 58's
# at boot, during nobody's.
case "$s" in 14) echo "metal-vmm: fired during client 1: DISK_REFUSE" >&2 ;; 45) echo "metal-vmm: fired during client 2: DISK_REFUSE" >&2 ;; esac
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
  53 | 55) ev Always "fat: at boot, a volume has no damage beyond what a stop leaves" true false; broken=1 ;;
  54) ev Always "fat: after a request, a volume has no damage beyond what a stop leaves" true false; ev Always "tcp: an always" true false; broken=2 ;;
  7) printf 'sound, written' > "$img"; ev Sometimes "tcp: only seed 7" true true ;;
  8) page=""; status=0; echo "metal-vmm: the first client gave up: it sent the same thing too often, unanswered" >&2 ;;
  10) page="hel"; echo "  let go at the end: 1 response(s) cut by the stop, 2 bytes never acknowledged" ;;
  12) page="not found"; status=404 ;;
  13) page="jello" ;;
  16 | 17) page=""; status=0; code=1; echo "error: GuestIdle" >&2 ;;
  14) page="Home unavailable"; status=500 ;;
  15 | 58) page="Home unavailable"; status=500 ;;
  18) page=""; status=0; echo "  serving 1 request(s), as gopher-metal.conf says"; echo "  served 1 request(s); base heap holds 52 live bytes"; echo "peer 2: 204, 1 of 1 answers, 65 bytes, done" ;;
  19) page=""; status=0; echo "  serving 1 request(s), as gopher-metal.conf says"; echo "  served 1 request(s); base heap holds 52 live bytes"; echo "peer 2: 0, 0 of 1 answers, 0 bytes, established" ;;
  23 | 24 | 25 | 26) printf 'UNSOUND' > "$img"; [ "$s" = 24 ] || echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2; [ "$s" != 25 ] || page="jello"
    lost=3; [ "$s" != 26 ] || lost=0
    [ "$s" = 24 ] || echo "metal-vmm: disk: a write cache, write-back, though the guest did not negotiate FLUSH (DISK_CACHE=lie); 4 writes held, 0 flushes; the power cut lost $lost sectors never flushed" >&2 ;;
  28) page=""; status=0 ;;
  31) printf 'STOPLEFT LOSTFILE' > "$img"; echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2 ;;
  33) [ -z "${VOLUME:-}" ] || printf 'STOPLEFT' > "$VOLUME"; echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2 ;;
  52) printf 'LOSTFILE' > "$img"; echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2 ;;
  32) printf 'STOPLEFT' > "$img"; echo "metal-vmm: the power was cut after the guest's write 2 (sector 9, 1 sectors)" >&2 ;;
  30) page=""; status=0; echo "  serving 2 request(s), as gopher-metal.conf says"; echo "request 1: (no request) -> the client stopped sending, and was let go"; echo "  served 2 request(s); base heap holds 52 live bytes"; echo "peer 2: 204, 1 of 1 answers, 65 bytes, done" ;;
  29) page="Home unavailable"; status=500 ;;
  27) page=""; status=0; echo "  serving 2 request(s), as gopher-metal.conf says"; echo "  served 2 request(s); base heap holds 52 live bytes"; echo "peer 2: 204, 1 of 1 answers, 65 bytes, done" ;;
  11) page="oops"; status=500; echo "  let go at the end: 1 response(s) cut by the stop, 2 bytes never acknowledged" ;;
esac
case "$s" in [2-9] | 1[0-9] | 2[3-9] | 30 | 52 | 53 | 54 | 55 | 58) ;; *) [ -z "${PEER_REQUEST:-}" ] || page="$(cat "${PEER_REQUEST%%,*}")" ;; esac
# A durable shape's write, and its read-back (QUEUE 125).
if [ "$page" = "WRITE" ]; then
  case "$s" in 35 | 36 | 46 | 47) ;; 48) printf ' CORRUPT' >> "$VOLUME" ;; *) printf ' written' >> "$VOLUME" ;; esac
  [ "$s" != 46 ] || { page=""; status=0; }
  case "$s" in 36 | 48) ;; *) false ;; esac && echo "metal-vmm: volume: a write cache that says it writes through (VOLUME_CACHE=lie); 1 reads, 2 writes, 0 SYNCHRONIZE CACHE, 1 MODE SENSE; the power failed when the guest stopped and lost sectors never synchronized" >&2
  [ "${VOLUME_CUT_AT_EXIT:-}" = 1 ] || { echo "a durable shape's run without VOLUME_CUT_AT_EXIT" >&2; exit 3; }
elif [ "$page" = "READBACK" ]; then
  page="$(cat "$VOLUME")"
elif [ "$page" = "READBACK404" ]; then
  page="$(cat "$VOLUME")"
  if grep -q CORRUPT "$VOLUME"; then page="failed"; status=500
  elif ! grep -q written "$VOLUME"; then page="no session"; status=404; fi
fi
# A request that is only "fail500" is answered 500: a shape gone stale.
[ "$page" != "fail500" ] || status=500
# **THE OTHER CLIENTS** (QUEUE 126): each pages its own request file (the
# last named, past the list), and says its line.
others=""
if [ "${PEER_CLIENTS:-1}" -gt 1 ]; then
  case "$s" in 39 | 42 | 51) page=""; status=0 ;; 57) page="pag"; echo "  let go at the end: 1 response(s) cut by the stop, 3 bytes never acknowledged" ;; esac
  IFS=, read -ra reqs <<< "$PEER_REQUEST"
  for ((k = 2; k <= PEER_CLIENTS; k++)); do
    r="${reqs[$(( k - 1 < ${#reqs[@]} ? k - 1 : ${#reqs[@]} - 1 ))]}"
    p2="$(cat "$r")"; s2=200; a2=1
    case "$s" in
      38) p2="another page" ;;
      39 | 41 | 42 | 57) p2="not found"; s2=404 ;;
      40 | 50) p2=""; s2=0; a2=0 ;;
      51) p2="oops"; s2=500 ;;
      45) p2="Home unavailable"; s2=500 ;;
    esac
    grep -q "REQUESTS=" "$img" || { p2=""; s2=0; a2=0; }
    printf '%s' "$p2" > "$PEER_BODY.$k"
    others="${others}peer $k: $s2, $a2 of 1 answers, ${#p2} bytes, done
"
  done
fi
if [ "$s" = 9 ] || { [ -z "$s" ] && [ -n "${FAKE_UNHURT_NO_PAGE:-}" ]; }; then
  echo "metal-vmm: the answer was 70000 bytes and the client keeps 65536; PEER_BODY and PEER_RESPONSE are not written" >&2
else
  printf '%s' "$page" > "$PEER_BODY"
fi
# The wire's account of the peer's frames, on stderr as metal-vmm prints it
# whenever the peer can lose one: it is not the status.
echo "peer: 51 frames sent, 1 lost (#3), 6309 ms of the guest's time" >&2
echo "peer: $status \"$page\""
[ "${PEER_CLIENTS:-1}" = 1 ] || { echo "peer 1: $status, 1 of 1 answers, ${#page} bytes, done"; printf '%s' "$others"; }
[ -n "${FAKE_NO_COVERAGE:-}" ] || echo "metal-vmm: coverage: 1 of 1 properties reached (1 hold, $broken broken), from 3 lines over 1 boots" >&2
exit $code
EOF
cat > "$T/sound" <<'EOF'
#!/bin/bash
if grep -q UNSOUND "$1"; then echo "  1 complaint"; exit 1; fi
if grep -q STOPLEFT "$1" && [ -n "${STOP_LEAVES:-}" ]; then echo "  sound but for what a stop leaves (2)"; exit 0; fi
if grep -q STOPLEFT "$1"; then echo "  2 complaints"; exit 1; fi
echo "  sound"
EOF
# The untouched files' check (tools/untouched.py): a run image saying
# LOSTFILE lost one.
cat > "$T/untouched" <<'EOF'
#!/bin/bash
[ "$1" != --ready ] || exit 0
if grep -q LOSTFILE "$3"; then echo "  /DATA/KEPT.MD: gone"; exit 1; fi
exit 0
EOF
# The site raised to serve n requests (tools/site_requests.py), as the fake
# machine reads it.
cat > "$T/site_requests" <<'EOF'
#!/bin/bash
cp "$1" "$2" && printf ' REQUESTS=%s' "$3" >> "$2"
EOF
chmod +x "$T/vmm" "$T/sound" "$T/untouched" "$T/site_requests"
# The unhurt run's largest write, as tools/largest_write.py says it: the fake
# volumes here are no FAT, and their stops leave no clusters.
printf '#!/bin/bash\necho 1\n' > "$T/largest_write_fake"; chmod +x "$T/largest_write_fake"
export UNTOUCHED="$T/untouched" SITE_REQUESTS="$T/site_requests" LARGEST_WRITE="$T/largest_write_fake"
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
# The failing seeds, for a program (QUEUE 135), last.
expect "the machine line" '^FAILED_SEEDS: 2 4 5 6$' "$out"
[ "$(tail -1 <<< "$out")" = "FAILED_SEEDS: 2 4 5 6" ] || { echo "FAIL: FAILED_SEEDS is not the last line"; fail=1; }
# Nothing judged is exit 2, a missing program among it (QUEUE 135).
VMM="$T/no-such-vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 1 > /dev/null 2>&1
[ $? = 2 ] || { echo "FAIL: a sweep with no metal-vmm did not exit 2"; fail=1; }

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
boot=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 58 58 2>&1)
expect "seed 58" '^58 .*FAIL: not the page (status 500)' "$boot"

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
letgo=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 30 30 2>&1)
leftovers=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 31 32 2>&1)
expect "seed 31" '^31 .*FAIL: the volume lost a file the request does not touch' "$leftovers"
clean=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 52 52 2>&1)
expect "seed 52" '^52 .*FAIL: the volume lost a file the request does not touch' "$clean"
expect "seed 32" '^32 .* ok ' "$leftovers"
machine=$(VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 33 33 2>&1)
expect "seed 33" '^33 .* ok ' "$machine"
expect "seed 30" '^30 .*FAIL: not the page (status 0)' "$letgo"
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
printf '  # b, a comment on a line of its own\nPEER_REQUEST=b.http\nEXPECT=200\n' > "$T/shapes/b.shape"
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

# **DURABILITY AS A SHAPE** (QUEUE 125): a shape that carries its read-back
# is judged on its page and on whether it kept what it was told it kept.
mkdir -p "$T/durable"
printf 'WRITE' > "$T/durable/w.http"
printf 'READBACK' > "$T/durable/r.http"
printf 'PEER_REQUEST=w.http\nEXPECT=200\nREAD_BACK=r.http\nMARK=written\n' > "$T/durable/w.shape"
kept=$(SHAPES="$T/durable" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 34 36 2>&1)
expect "the durable shape's guard" 'shape w: each seed is read back with r.http for "written"' "$kept"
expect "seed 34" '^34 *w .* ok ' "$kept"
expect "seed 35" '^35 *w .*FAIL: told 200 and the write is not on the volume' "$kept"
expect "seed 36" '^36 *w .*allowed: VOLUME_CACHE=lie (the write lost)' "$kept"
# A recipe that does not hold stops the sweep: the unhurt run must keep MARK.
printf 'PEER_REQUEST=w.http\nEXPECT=200\nREAD_BACK=r.http\nMARK=never\n' > "$T/durable/w.shape"
SHAPES="$T/durable" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 34 34 > "$T/durable.out" 2>&1
[ $? = 2 ] || { echo "FAIL: a durable shape whose unhurt run keeps no MARK did not stop the sweep with 2"; fail=1; }
expect "the recipe that does not hold" 'shape w: its unhurt run was told 200 and its read-back lacks "never"' "$(cat "$T/durable.out")"

# **DAMAGE THE DISK WAS DEALT** (QUEUE 128): a broken "no damage" property
# is excused by a damaging fault that fired, and nothing else is.
rot=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 53 55 2>&1)
expect "seed 53" '^53 .*allowed: DISK_ROT (fat: at boot, a volume has no damage beyond what a stop leaves)' "$rot"
expect "seed 54" '^54 .*FAIL: 2 coverage properties broken' "$rot"
expect "seed 55" '^55 .*FAIL: 1 coverage properties broken' "$rot"
# The excused break is not the merged report's failure either: left out of
# it, and said, the seed's own coverage file keeping it.
alone=$(VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 53 53 2>&1)
[ $? = 0 ] || { echo "FAIL: a sweep whose one break the damage dealt excuses did not pass:"; echo "$alone" | sed 's/^/    /'; fail=1; }
expect "the break left out, and said" 'left out of the merged report, each excused by the damage its seed was dealt: 53' "$alone"
if grep -q '^FAIL  *Always  *fat: at boot' <<< "$alone"; then echo "FAIL: an excused damage break failed the merged report"; fail=1; fi
if ! grep -q '^FAIL  *Always  *fat: at boot' <<< "$rot"; then echo "FAIL: seed 55's unexcused damage break left the merged report"; fail=1; fi

# **EVERY CLIENT JUDGED** (QUEUE 126): two clients, at once (p) and in turn
# (q), each held to the same client unhurt.
mkdir -p "$T/clients"
printf 'page a' > "$T/clients/a.http"
printf 'page b' > "$T/clients/b.http"
printf 'PEER_CLIENTS=2\nPEER_REQUEST=a.http,b.http\nEXPECT=200,200\n' > "$T/clients/p.shape"
printf 'PEER_CLIENTS=2\nPEER_IN_TURN=1\nPEER_REQUEST=a.http,b.http\nEXPECT=200,200\nUNMADE=404\n' > "$T/clients/q.shape"
both=$(SHAPES="$T/clients" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 38 45 2>&1)
expect "shape p's unhurt clients" '^shape p: unhurt status 200,200, 6 bytes' "$both"
expect "shape p's site, raised" '^shape p: the site raised to 2 requests' "$both"
expect "a repeat on the raised site" 'repeat it: .*PEER_CLIENTS=2 .*VOLUME=<a copy of the volume, after the setup> .*<a copy of the site, its requests raised by tools/site_requests.py to 2> "" /' "$both"
expect "seed 38" '^38 *p .*FAIL: client 2: not its page (status 200; unhurt: 200)' "$both"
expect "seed 39" "^39 *q .*differs (allowed: PEER_RESET_AT, client 2: a 404 as UNMADE allows, after client 1's answer differed)" "$both"
expect "seed 40" '^40 *p .*differs (allowed: client 2: PEER_VANISH_AFTER)' "$both"
expect "seed 41" '^41 *q .*FAIL: client 2: not its page (status 404; unhurt: 200)' "$both"
expect "seed 42" '^42 *p .*FAIL: client 2: not its page (status 404; unhurt: 200)' "$both"
expect "seed 43" '^43 *q .* ok ' "$both"
expect "seed 44" '^44 *p .* ok ' "$both"
expect "seed 45" '^45 *q .*differs (allowed: client 2: DISK_REFUSE (a 500))' "$both"
expect "the summary" '^8 seeds: 2 ok, 3 differ as their faults allow, 3 failed' "$both"
more=$(SHAPES="$T/clients" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 50 51 2>&1)
expect "seed 50" '^50 *p .*FAIL: client 2: not its page (status 0; unhurt: 200)' "$more"
expect "seed 51" '^51 *q .*FAIL: client 2: not its page (status 500; unhurt: 200)' "$more"
cutshort=$(SHAPES="$T/clients" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 57 57 2>&1)
expect "seed 57" '^57 *q .*FAIL: client 2: not its page (status 404; unhurt: 200)' "$cutshort"
# A shape of two clients that names one status holds client 2 to nothing.
printf 'PEER_CLIENTS=2\nPEER_REQUEST=a.http,b.http\nEXPECT=200\n' > "$T/clients/p.shape"
SHAPES="$T/clients" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 44 44 > "$T/clients.out" 2>&1
[ $? = 2 ] || { echo "FAIL: a two-client shape with one EXPECT did not stop the sweep with 2"; fail=1; }
expect "one status for two clients" 'shape p: EXPECT names 1 status(es) for 2 client(s)' "$(cat "$T/clients.out")"
# Nor may client 2's unhurt answer be other than its EXPECT.
printf 'PEER_CLIENTS=2\nPEER_REQUEST=a.http,b.http\nEXPECT=200,204\n' > "$T/clients/p.shape"
SHAPES="$T/clients" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 44 44 > "$T/clients.out" 2>&1
[ $? = 2 ] || { echo "FAIL: a client 2 whose unhurt answer is not its EXPECT did not stop the sweep with 2"; fail=1; }
expect "client 2 not as expected" 'shape p: its unhurt run answered 200,200, not 200,204' "$(cat "$T/clients.out")"

# **A READ-BACK THAT IS NOT 200** (QUEUE 127(c), (f)): as the pristine
# volume's when the run was not told; a 500 a lying cache's loss caused.
mkdir -p "$T/durable404"
printf 'WRITE' > "$T/durable404/w.http"
printf 'READBACK404' > "$T/durable404/r.http"
printf 'PEER_REQUEST=w.http\nEXPECT=200\nREAD_BACK=r.http\nMARK=written\n' > "$T/durable404/w.shape"
notfound=$(SHAPES="$T/durable404" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 46 48 2>&1)
expect "seed 46" '^46 *w .*differs (allowed: PEER_RESET_AT)  ' "$notfound"
expect "seed 47" '^47 *w .*FAIL: told 200 and the write is not on the volume' "$notfound"
expect "seed 48" '^48 *w .*allowed: VOLUME_CACHE=lie (the read-back failed, 500)' "$notfound"

# **COUNTED_LEAK, ITS CEILING AND ITS FLOOR** (148's review): fsck finds
# no more than K clusters and no fewer than K - U, the exact part; an exact
# orphaned part means at least one orphaned name. Each line of each kind.
eval "$(sed -n '/^counted_leak() {$/,/^}$/p' "$HERE/sweep.sh")"
leak() { # leak <reclaimed> <orphan lines> <K> <P> <F> [U V]: counted_leak's verdict
  { echo "fsck"; [ "$1" = 0 ] || echo "  Reclaimed $1 unused clusters (512 bytes)."
    for _ in $(seq 1 "$2"); do echo "  Orphaned long file name part \"x\""; echo "    Auto-deleting."; done; } > "$T/leak.sound"
  if [ $# -ge 7 ]; then
    echo "  the volume: $3 clusters left a counted leak, $4 long-name parts left orphaned, $5 FAT copy writes failed; of the clusters and parts, $6 and $7 may be live; 0 leaks of a size not known (K no ceiling while any); 0 clusters past a size (0 cleanups failed)"
  else
    echo "  the volume: $3 clusters left a counted leak, $4 long-name parts left orphaned, $5 FAT copy writes failed (0 cleanups failed)"
  fi > "$T/leak.out"
  counted_leak "$T/leak.sound" "$T/leak.out" "the volume" > /dev/null && echo allowed || echo refused
}
expect "B42's line, 2 of 2" allowed "$(leak 2 0 2 0 0)"
expect "B42's line, 3 of 2" refused "$(leak 3 0 2 0 0)"
expect "B42's line, 1 of 2 exact" refused "$(leak 1 0 2 0 0)"
expect "148's line, 1 of 3, 2 may be live" allowed "$(leak 1 0 3 0 0 2 0)"
expect "148's line, 1 of 3, 1 may be live" refused "$(leak 1 0 3 0 0 1 0)"
expect "148's line, 4 of 3" refused "$(leak 4 0 3 0 0 3 0)"
expect "148's line, a name of 3 exact parts" allowed "$(leak 0 1 0 3 0 0 0)"
expect "148's line, 2 names of 3 parts" allowed "$(leak 0 2 0 3 0 0 0)"
expect "148's line, a leak but no name of 3 exact parts" refused "$(leak 1 0 1 3 0 0 0)"
expect "148's line, a leak and no name of 3 parts may be live" allowed "$(leak 1 0 1 3 0 0 3)"
# 152's line: fsck's names held to R, not to P.
runs() { # runs <orphan lines> <P> <R>: counted_leak's verdict
  { echo "fsck"; for _ in $(seq 1 "$1"); do echo "  Orphaned long file name part \"x\""; echo "    Auto-deleting."; done; } > "$T/leak.sound"
  echo "  the volume: 0 clusters left a counted leak, $2 long-name parts left orphaned in $3 runs, 0 FAT copy writes failed; of the clusters and parts, 0 and 0 may be live; 0 leaks of a size not known (K no ceiling while any); 0 clusters past a size (0 cleanups failed)" > "$T/leak.out"
  counted_leak "$T/leak.sound" "$T/leak.out" "the volume" "$T/leak.img" > /dev/null && echo allowed || echo refused
}
expect "152's line, a name of 3 parts" allowed "$(runs 1 3 1)"
expect "152's line, 2 names counted as 1 of 3 parts" refused "$(runs 2 3 1)"
expect "152's line, 2 names of 3 parts" allowed "$(runs 2 3 2)"

# **A CHAIN PAST ITS SIZE** (148(c)): fsck's in-use count 3, the FAT's taken
# (a fake tools/fat_taken.py) 7, nothing reclaimed: 4 clusters past the size,
# held to the kernel's L.
printf '#!/bin/bash\necho "$FAKE_TAKEN"\n' > "$T/fat_taken"; chmod +x "$T/fat_taken"
long() { # long <L> <second line> <third line> [taken]: counted_leak's verdict on one file truncated
  printf '  1 files, 3/78736 clusters\n  /BIG.BIN\n%s\n%s\n  Leaving filesystem unchanged.\n' "$2" "$3" > "$T/leak.sound"
  echo "  the volume: 0 clusters left a counted leak, 0 long-name parts left orphaned, 0 FAT copy writes failed; of the clusters and parts, 0 and 0 may be live; 0 leaks of a size not known (K no ceiling while any); $1 clusters past a size (0 cleanups failed)" > "$T/leak.out"
  FAT_TAKEN="$T/fat_taken" FAKE_TAKEN="${4:-7}" counted_leak "$T/leak.sound" "$T/leak.out" "the volume" "$T/leak.img" > /dev/null && echo allowed || echo refused
}
past="    File size is 1000 bytes, cluster chain length is > 1024 bytes."
cut="    Truncating file to 1000 bytes."
expect "a chain 4 past its size, L 4" allowed "$(long 4 "$past" "$cut")"
expect "a chain 4 past its size, L 5" allowed "$(long 5 "$past" "$cut")"
expect "a chain 4 past its size, L 3" refused "$(long 3 "$past" "$cut")"
expect "a truncation the FAT does not show, L 4" refused "$(long 4 "$past" "$cut" 3)"
expect "a size past its chain (a file cut short), L 4" refused "$(long 4 "    File size is 1000 bytes, cluster chain length is 512 bytes." "    Truncating file to 512 bytes.")"
expect "a chain past its size, no truncation said, L 4" refused "$(long 4 "$past" "    Contains a free cluster (116). Assuming EOF.")"

# **WHAT A STOP LEAVES, HELD TO ONE OPERATION'S WORTH** (the normalization
# hunt): the unhurt run's largest write (a fake tools/largest_write.py: 75,
# a 74-cluster file and a folder grown); one orphaned name. Beyond the
# kernel's count.
eval "$(sed -n '/^stop_leftovers() {$/,/^}$/p' "$HERE/sweep.sh")"
printf '#!/bin/bash\necho 75\n' > "$T/largest_write"; chmod +x "$T/largest_write"
stop() { # stop <reclaimed> <orphan lines> [K R]: stop_leftovers' verdict
  { echo "  1 files, 3/78736 clusters"
    [ "$1" = 0 ] || echo "  Reclaimed $1 unused clusters ($(( $1 * 512 )) bytes)."
    for _ in $(seq 1 "$2"); do echo "  Orphaned long file name part \"x\""; done
    echo "  sound but for what a stop leaves (1)"; } > "$T/stop.sound"
  if [ $# -ge 4 ]; then
    echo "  the volume: $3 clusters left a counted leak, $4 long-name parts left orphaned in $4 runs, 0 FAT copy writes failed; of the clusters and parts, 0 and 0 may be live; 0 leaks of a size not known (K no ceiling while any); 0 clusters past a size (0 cleanups failed)"
  else echo "metal-vmm: the power was cut after the guest's write 9 to the volume"; fi > "$T/stop.out"
  LARGEST_WRITE="$T/largest_write" stop_leftovers "$T/stop.sound" "$T/stop.out" "the volume" "$T/p.img" "$T/u.img" > /dev/null && echo allowed || echo refused
}
expect "a stop: one file's clusters" allowed "$(stop 74 0)"
expect "a stop: one file's clusters and a folder grown" allowed "$(stop 75 1)"
expect "a stop: 500 clusters, one operation's worth is 75" refused "$(stop 500 0)"
expect "a stop: two orphaned names, one operation leaves one" refused "$(stop 1 2)"
expect "a stop beside the kernel's count: 80 clusters, 10 counted" allowed "$(stop 80 0 10 0)"
expect "a stop beside the kernel's count: 86 clusters, 10 counted" refused "$(stop 86 0 10 0)"
expect "a stop beside the kernel's count: two names, one counted" allowed "$(stop 1 2 0 1)"
printf '#!/bin/bash\nexit 1\n' > "$T/largest_write_fails"; chmod +x "$T/largest_write_fails"
expect "a stop whose unhurt run cannot be read is refused" refused "$(cp "$T/largest_write_fails" "$T/largest_write"; stop 1 0)"

# **A COVERAGE LINE THAT CANNOT BE READ IS A BREAK** (the normalization
# hunt): it was skipped, and could hide a break beside one a fault excuses.
eval "$(sed -n '/^broken_props() {$/,/^}$/p' "$HERE/sweep.sh")"
mkdir -p "$T/covwork"
{ echo '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"m","condition":true,"id":"held"}}'
  echo '{"antithesis_assert":{"hit":true,"must_h'; } > "$T/covwork/garbled.cov"
expect "a garbled coverage line is a break of its own" "a coverage line that cannot be read" "$(WORK="$T/covwork" broken_props garbled)"

# **A SHAPE'S VALUE KEEPS ITS #, AND A KEY NO ONE READS STOPS THE SWEEP**
# (the normalization hunt): `MARK=msg#1` was cut to `MARK=msg`, and a key in
# no setting's family (a misspelt EXPECT) went to metal-vmm, unread.
mkdir -p "$T/keys"
printf 'X' > "$T/keys/k.http"
printf 'PEER_REQUEST=k.http\nEXPECT=200\nEXPCT=404\n' > "$T/keys/k.shape"
keys=$(SHAPES="$T/keys" VOLUME_SITE="$T/site.img" VMM="$T/vmm" SOUND="$T/sound" KERNEL="$T/kernel.elf" SITE="$T/site.img" "$HERE/sweep.sh" 1 1 2>&1)
expect "a misspelt shape key stops the sweep" "EXPCT is no shape key and no metal-vmm setting" "$keys"

if [ $fail = 0 ]; then echo "sweep_test: every verdict and the summary as told"; fi
exit $fail
