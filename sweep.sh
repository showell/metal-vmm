#!/bin/bash
# **A SEED SWEEP: ONE KERNEL, ONE VOLUME, A RANGE OF WHOLE FAULT SCHEDULES.**
#
#   ./sweep.sh [first] [last]     # FAULT_SEED 1 to 100 by default
#
# Each seed is one exact run (knobs.zig): which frames each way are lost or
# damaged, how late they arrive, which disk request is refused, how the peer
# misbehaves. Every run gets a fresh copy of the volume, and the sweep stops
# at nothing. Each run's verdict:
#
#   - its exit must be the unhurt run's: a crash, a stuck guest or a refused
#     start is a failure whatever the faults were;
#   - it must break no coverage property (metal-vmm's "N broken"), so the
#     kernel must be built -Dcoverage: one whose unhurt run reports no
#     property stops the sweep before any seed, since it would judge none.
#     But the kernel's own "no damage" check, broken by a fault that wrote
#     damage and fired (DISK_ROT, DISK_TEAR, DISK_BAD_SECTOR, a lying cache
#     that lost what it held), is allowed, and left out of the merged report
#     (QUEUE 128); any other break fails;
#   - a volume the guest wrote must still be a filesystem (sound.sh): after
#     a power cut, but for what a stop leaves; and a disk that lied about its
#     cache (`*_CACHE=lie`), then lost its power and with it writes it held,
#     is excused (Steve, 2026-10-09), as the durability judge excuses its
#     lost write; a lie whose cut lost nothing excuses nothing;
#   - the page must be the unhurt run's, status and body, unless the seed
#     reset the connection, made the peer vanish, refused a disk request or
#     cut the power, which may rightly cost the page: then it is "differs
#     (allowed: ...)". Each such fault must have fired, as metal-vmm's
#     `fired:` line says: a knob drawn whose moment never came excuses
#     nothing (metal-vmm QUEUE 124(e)). A 5xx is excused only by a disk
#     or volume fault that fired while that client's request was open, as
#     the `fired during client k:` line says (QUEUE 138(d)). A cut volume must still be sound: that is FAT's crash
#     consistency, measured.
#
# Every run's coverage goes to one JSONL, judged at the end by
# zig-coverage-sdk's tools/report.py, which names each run by its seed (with
# FLOOR=<file> if set). The sweep ends with the failing seeds, each as
# the knobs that repeat it without the seed, and then one line for a
# program, `FAILED_SEEDS: 3 17 42` (empty when none). It exits 1 if any seed
# failed or the merge did, and 2, always, when nothing can be judged.
#
# **MANY SHAPES OF REQUEST** (`SHAPES=<dir>`): each `<name>.shape` there is
# a request's setting, one VAR=value a line (`#` for comments), passed to
# every run of it: `PEER_REQUEST=a[,b]` (files in the same folder),
# `PEER_CLIENTS=2`, any knob, and `EXPECT=<status>`, which the
# shape's unhurt run must answer or nothing can be judged; every shape has
# one. **EVERY CLIENT IS JUDGED** (metal-vmm QUEUE 126): a shape of n clients
# names n statuses (`EXPECT=303,204`), one for each client's unhurt answer,
# and each client is held to the same client in the unhurt run, as the
# first is (client k's page is metal-vmm's `<PEER_BODY>.k`). With
# `PEER_IN_TURN=1` each client asks after the one before was answered, so a
# request may depend on the last one's write (a move in the session it
# made): then, once an earlier client's answer differed so that its write
# is in doubt (no answer, a 5xx, another status), a later one may
# also answer what the shape's `UNMADE=<status>[,...]` names (a 404: the
# session was never made), and nothing its own faults do not excuse.
# The site's own limit (`requests = 1`) ends a run, so a shape of n clients
# asking k times each boots from a copy of SITE raised to n x k
# (`tools/site_requests.py`, QUEUE 127(h); SITE_REQUESTS names another). **A WRITE SHAPE MAY CARRY ITS READ-BACK** (metal-vmm QUEUE 125):
# `READ_BACK=<request file beside it, or a path>`, `MARK=<text>` and
# `TOLD=<status>` (its EXPECT unless said). Its runs then lose at the end what
# no cache synchronized (VOLUME_CUT_AT_EXIT=1), each seed's volume is read
# back by an unhurt boot, and a seed told TOLD whose read-back lacks MARK
# fails, beside its page's verdict, as a durability sweep's does. Its
# unhurt run must keep MARK, and the pristine volume must not hold it. Seed s is the
# shape (s mod n) of the n in name order, judged against that shape's
# unhurt run. An optional `setup` file there names requests (one a line)
# sent first, each an unhurt boot, to a copy of VOLUME_SITE that every run
# then starts from: a player made, so a request with its cookie is answered
# as that player.
#
# Environment: GUESTS, SITE and PATH_WANTED (default /) as pc_vs_microvm.sh has them;
# TRANSPORT (default pci, the machine that rests); FLOOR; RUN_TIMEOUT
# (seconds a run, default 300); JOBS (2: runs side by side);
# KEEP_FAILED=<dir>: a failing seed's files kept; KEEP=<dir> keeps every
# run's log, page and the coverage JSONL there. VMM, REPORT and SOUND name the programs, for a test;
# REPORT is $COVERAGE_SDK/tools/report.py, the SDK a sibling checkout unless
# COVERAGE_SDK says where (as gopher-metal's long.sh reads it).
# VOLUME_SITE=<image> attaches a fresh copy of that image to every run as its
# volume (scsi.zig), so each seed also draws the volume's faults
# (knobs.zig, `withVolume`); its copy must be sound too, and VOLUME_CUT_AFTER
# may cost the page as DISK_CUT_AFTER does. Unset, nothing here changes.
#
# **A SWEEP THAT JUDGES DURABILITY, NOT THE PAGE** (QUEUE item 70): with
# POST=<request file>, READ_BACK=<path, or a request file> and MARK=<text>,
# and VOLUME_SITE,
# every run sends POST's bytes (a chat post, with its session cookie) instead
# of asking for a page, with VOLUME_CUT_AT_EXIT=1, so each write cache loses
# what was never synchronized when the guest stops. Then the same kernel is
# booted again, unhurt, on a copy of that volume, and asked for READ_BACK.
# The verdict:
#
#   - **told 303, and MARK is not in the read-back: FAIL**, whatever else the
#     seed did, but where the volume's cache lied (VOLUME_CACHE=lie: WCE=0 is
#     believed) or a SYNCHRONIZE CACHE failed (VOLUME_SYNC_FAIL: the response
#     goes out anyway, by design), which are "lost (allowed: ...)";
#   - not told 303: nothing was promised, kept or not;
#   - a read-back boot that gets no page: FAIL.
#
# 303 is what a chat post is told when it is saved; `TOLD=<status>` names
# another (a puzzle move's 204). The page is not compared. The unhurt run
# must be told TOLD and keep MARK,
# and the pristine volume must not hold it, or nothing can be judged.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# **NOTHING CAN BE JUDGED: EXIT 2, ALWAYS, THROUGH HERE** (metal-vmm QUEUE
# 135): a missing program, a shape that says nothing, an unhurt run that
# answers otherwise. Exit 1 is only seeds that failed, or the coverage
# report; a night stops on 2 and goes on after 1.
cannot_judge() { [ $# = 0 ] || echo "$*"; exit 2; }
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
KERNEL="${KERNEL:-$GUESTS/gopher.elf}"
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
PATH_WANTED="${PATH_WANTED:-/}"
FIRST="${1:-1}"
LAST="${2:-100}"
VMM="${VMM:-$HERE/zig-out/bin/metal-vmm}"
COVERAGE_SDK="${COVERAGE_SDK:-$HERE/../zig-coverage-sdk}"
REPORT="${REPORT:-$COVERAGE_SDK/tools/report.py}"
SOUND="${SOUND:-$HERE/sound.sh}"
# The untouched files' check (tools/untouched.py), with gopher-metal's FAT
# reader beside the guests unless FAT_READ says where.
UNTOUCHED="${UNTOUCHED:-$HERE/tools/untouched.py}"
FAT_TAKEN="${FAT_TAKEN:-$HERE/tools/fat_taken.py}"
# The site raised to serve a shape's every request (tools/site_requests.py).
SITE_REQUESTS="${SITE_REQUESTS:-$HERE/tools/site_requests.py}"
[ -n "${FAT_READ:-}" ] || [ ! -f "$GUESTS/../tools/fat16_read.py" ] || export FAT_READ="$GUESTS/../tools/fat16_read.py"
export TRANSPORT="${TRANSPORT:-pci}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
if [ -n "${KEEP:-}" ]; then WORK="$KEEP"; mkdir -p "$WORK"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi
[ -x "$VMM" ] || cannot_judge "no $VMM; run: zig build"
[ -f "$REPORT" ] || cannot_judge "no $REPORT; set COVERAGE_SDK=<zig-coverage-sdk checkout>"
[ -f "$KERNEL" ] || cannot_judge "no $KERNEL"
[ -f "$SITE" ] || cannot_judge "no volume at $SITE; set SITE=<image>"
# **THE CHECK A CUT NEEDS, READY BEFORE ANY SEED** (QUEUE 127(a)): a missing
# untouched.py or FAT reader would fail every cut seed with stop leftovers
# as "lost a file", all night. Exit 2: nothing can be judged, and a night
# stops.
"$UNTOUCHED" --ready > "$WORK/untouched.ready" 2>&1 || { echo "$UNTOUCHED --ready failed: a cut's leftovers could not be judged:"; sed 's/^/  /' "$WORK/untouched.ready"; cannot_judge; }
DURABLE=""
if [ -n "${POST:-}" ]; then
  [ -f "$POST" ] || cannot_judge "no request at POST=$POST"
  [ -n "${READ_BACK:-}" ] && [ -n "${MARK:-}" ] || cannot_judge "POST needs READ_BACK=<path> and MARK=<text>"
  [ -n "${VOLUME_SITE:-}" ] || cannot_judge "POST needs VOLUME_SITE=<image>: the message is kept on the volume"
  DURABLE=yes
fi
TOLD="${TOLD:-303}"
COVERAGE="$WORK/coverage.jsonl"
: > "$COVERAGE"

# The shapes: their names, and each one's settings as VAR=value words, the
# request files made absolute. No SHAPES is one shape, named "", with none.
SHAPE_NAMES=("")
declare -A SHAPE_ENV=() SHAPE_EXPECT=() SHAPE_READ=() SHAPE_MARK=() SHAPE_TOLD=() SHAPE_UNMADE=()
# setting_of <shape> <VAR>: that setting's value in the shape (or, for no
# shape, the environment's).
setting_of() {
  if [ -z "$1" ]; then printenv "$2"; return 0; fi
  local w
  for w in ${SHAPE_ENV[$1]:-}; do case "$w" in "$2="*) echo "${w#"$2"=}" ;; esac; done
  return 0
}
# clients_of <shape>: how many clients it is (PEER_CLIENTS, 1 unless said;
# metal-vmm holds it to 8). in_turn_of <shape>: whether they ask in turn.
clients_of() { local c; c=$(setting_of "$1" PEER_CLIENTS); echo "${c:-1}"; }
in_turn_of() { [ "$(setting_of "$1" PEER_IN_TURN)" = 1 ]; }
asks_of() { local a; a=$(setting_of "$1" PEER_ASKS); echo "${a:-1}"; }
# site_of <shape>: the boot disk its runs start from: the site, or the copy
# raised to serve all its requests (QUEUE 127(h)).
site_of() { if [ -f "$WORK/site-${1:-none}.img" ]; then echo "$WORK/site-${1:-none}.img"; else echo "$SITE"; fi; }
if [ -n "${SHAPES:-}" ]; then
  [ -d "$SHAPES" ] || cannot_judge "no folder at SHAPES=$SHAPES"
  [ -z "$DURABLE" ] || cannot_judge "SHAPES and POST are two sweeps; choose one"
  SHAPES="$(cd "$SHAPES" && pwd)"
  SHAPE_NAMES=()
  for f in "$SHAPES"/*.shape; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .shape)
    SHAPE_NAMES+=("$n")
    words=""
    while IFS= read -r line; do
      line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in
        EXPECT=*) SHAPE_EXPECT[$n]="${line#EXPECT=}" ;;
        # **DURABILITY AS A SHAPE** (metal-vmm QUEUE 125): its read-back
        # request (a file beside it) or path, the text a kept write leaves
        # in it, and the status that promises it (EXPECT unless said).
        READ_BACK=*)
          v="${line#READ_BACK=}"
          [ ! -f "$SHAPES/$v" ] || v="$SHAPES/$v"
          SHAPE_READ[$n]="$v" ;;
        MARK=*) SHAPE_MARK[$n]="${line#MARK=}" ;;
        TOLD=*) SHAPE_TOLD[$n]="${line#TOLD=}" ;;
        # In turn, what a client answers when what an earlier one should
        # have made is not there (QUEUE 127(d)): `UNMADE=404`.
        UNMADE=*) SHAPE_UNMADE[$n]="${line#UNMADE=}" ;;
        PEER_REQUEST=*)
          files=""
          IFS=, read -ra parts <<< "${line#PEER_REQUEST=}"
          for part in "${parts[@]}"; do
            [ -f "$SHAPES/$part" ] || cannot_judge "shape $n: no request $SHAPES/$part"
            files="$files${files:+,}$SHAPES/$part"
          done
          words="$words PEER_REQUEST=$files" ;;
        *=*) words="$words $line" ;;
        *) cannot_judge "shape $n: not VAR=value: $line" ;;
      esac
    done < "$f"
    SHAPE_ENV[$n]="${words# }"
    # **EVERY SHAPE SAYS WHAT ITS UNHURT RUN MUST ANSWER** (metal-vmm QUEUE
    # 122): with none, a shape gone stale (a cookie expired, a 500) is every
    # seed's baseline, and every seed that fails as it does is "ok".
    [ -n "${SHAPE_EXPECT[$n]:-}" ] || cannot_judge "shape $n: no EXPECT=<status>: its unhurt run is held to nothing, so nothing can be judged"
    # One status a client (QUEUE 126): a client held to nothing would judge
    # every seed against an answer gone stale.
    want=$(clients_of "$n")
    IFS=, read -ra statuses <<< "${SHAPE_EXPECT[$n]}"
    [ "${#statuses[@]}" = "$want" ] || cannot_judge "shape $n: EXPECT names ${#statuses[@]} status(es) for $want client(s): each client's unhurt answer must be held to one (EXPECT=303,204 for two), so nothing can be judged"
    if [ -n "${SHAPE_READ[$n]:-}" ]; then
      [ -n "${SHAPE_MARK[$n]:-}" ] || cannot_judge "shape $n: READ_BACK needs MARK=<text>"
      [ -n "${VOLUME_SITE:-}" ] || cannot_judge "shape $n: READ_BACK needs VOLUME_SITE=<image>: the write is kept on the volume"
      SHAPE_TOLD[$n]="${SHAPE_TOLD[$n]:-${SHAPE_EXPECT[$n]%%,*}}"
      # Each write cache loses what was never synchronized when the guest
      # stops, as in a durability sweep.
      SHAPE_ENV[$n]="${SHAPE_ENV[$n]}${SHAPE_ENV[$n]:+ }VOLUME_CUT_AT_EXIT=1"
    fi
  done
  [ ${#SHAPE_NAMES[@]} -gt 0 ] || cannot_judge "no *.shape in $SHAPES"
fi
# shape_env <shape>: its settings ("" for none).
shape_env() { [ -z "$1" ] || echo "${SHAPE_ENV[$1]}"; }
# shape_of <seed>: the name of the shape that seed sends.
shape_of() { echo "${SHAPE_NAMES[$(( $1 % ${#SHAPE_NAMES[@]} ))]}"; }
# unhurt_of <shape>: the name of that shape's unhurt run.
unhurt_of() { if [ -z "$1" ]; then echo unhurt; else echo "unhurt-$1"; fi; }

# run <name> [VAR=value ...]: one boot on a fresh volume; its exit, log and page.
#
# Each run's coverage goes to a file of its own, joined in order at the end,
# so runs side by side (`JOBS`) give the merged report the order alone does.
# The images' modification times are noted after the copy: metal-vmm writes
# an image back only when the guest changed it, so an image whose time has
# not moved holds what it was copied from, and is not compared byte for byte
# (64 MB of holes, 70 ms a compare).
run() {
  local name="$1"; shift
  local site="${RUN_SITE:-$SITE}"
  cp "$site" "$WORK/$name.img"
  stat -c %y "$WORK/$name.img" > "$WORK/$name.img.copied"
  local volume=() post=()
  if [ -n "${VOLUME_SITE:-}" ]; then
    cp "$VOLUME_SITE" "$WORK/$name.vol"
    stat -c %y "$WORK/$name.vol" > "$WORK/$name.vol.copied"
    volume=(VOLUME="$WORK/$name.vol")
  fi
  [ -z "$DURABLE" ] || post=(PEER_REQUEST="$POST" VOLUME_CUT_AT_EXIT=1)
  env "$@" "${volume[@]}" "${post[@]}" COVERAGE_OUT="$WORK/$name.cov" PEER_BODY="$WORK/$name.body" \
    timeout "$RUN_TIMEOUT" "$VMM" "$KERNEL" "$WORK/$name.img" "" "$PATH_WANTED" > "$WORK/$name.out" 2> "$WORK/$name.err"
  echo $? > "$WORK/$name.exit"
  # No page stays no page: metal-vmm writes none for an answer it kept only
  # in part, and an empty one would match another empty one.
}

# read_back <name> [volume] [request]: an unhurt boot on a copy of that run's
# volume (or the one named), asking for READ_BACK (or the request named: a
# durable shape's); its page in <name>.read, its status in <name>.readstatus.
# The run's own volume stays as the run left it, for sound.sh.
read_back() {
  local name="$1" vol="${2:-$WORK/$1.vol}" request="${3:-${READ_BACK:-}}"
  cp "$SITE" "$WORK/$name.readimg"
  cp "$vol" "$WORK/$name.readvol"
  # A path, or a request file (one that carries a cookie, say).
  local ask=() path="$request"
  if [ -f "$request" ]; then ask=(PEER_REQUEST="$request"); path=/; fi
  env "${ask[@]}" VOLUME="$WORK/$name.readvol" PEER_BODY="$WORK/$name.read" \
    timeout "$RUN_TIMEOUT" "$VMM" "$KERNEL" "$WORK/$name.readimg" "" "$path" > "$WORK/$name.readout" 2> "$WORK/$name.readerr"
  [ -f "$WORK/$name.read" ] || : > "$WORK/$name.read"
  sed -n -E 's/^peer: ([0-9]+)( "|, [0-9]+ bytes$).*/\1/p' "$WORK/$name.readout" | head -1 > "$WORK/$name.readstatus"
  rm -f "$WORK/$name.readimg" "$WORK/$name.readvol"
}
# kept <name> [mark]: whether that read-back holds MARK (or the mark named).
kept() { grep -qF -- "${2:-$MARK}" "$WORK/$1.read"; }
# told_of <run> <shape>: the status a durable shape's TOLD is held to: the
# first client's, or every client's, comma-separated, when TOLD names each
# (metal-vmm QUEUE 149: `two-clients` and `session-then-move` keep what both
# were told, and a write the second makes is promised only when it was told
# too).
told_of() {
  case "${SHAPE_TOLD[$2]:-}" in
    *,*) statuses_of "$1" "$2" ;;
    *) status_of "$1" ;;
  esac
}

# read_of <shape>: its read-back request, if it is a durable shape.
read_of() { [ -z "$1" ] || echo "${SHAPE_READ[$1]:-}"; }

# The client's own line (`peer: 200 "..."` or `peer: 200, 13668 bytes`), not
# the wire's account of the peer's frames (`peer: 51 frames sent, ...`),
# which a run whose peer loses frames prints first.
# **EACH FACT FROM THE STREAM THAT CARRIES IT.** A run's stdout is the
# guest's console and the client's line (`peer: 200, 13668 bytes`); its
# stderr is what metal-vmm says itself (the knobs a seed drew, the wire's
# account of the peer's frames, how the peer ended, the coverage line). Read
# together, the wire's "peer: 51 frames sent" was once taken for a status.
status_of() { sed -n -E 's/^peer: ([0-9]+)( "|, [0-9]+ bytes$).*/\1/p' "$WORK/$1.out" | head -1; }
# client_status <run> <k>: client k's status, from its own line (`peer 2:
# 204, 1 of 1 answers, 65 bytes, done`); none for a client never opened.
client_status() { sed -n -E "s/^peer $2: ([0-9]+), .*/\1/p" "$WORK/$1.out" | head -1; }
# client_page <run> <k>: client k's page file (metal-vmm's PEER_BODY, and
# `<PEER_BODY>.k` for client k past the first; QUEUE 126).
client_page() { if [ "$2" = 1 ]; then echo "$WORK/$1.body"; else echo "$WORK/$1.body.$2"; fi; }
# statuses_of <run> <shape>: every client's status, comma-separated, as a
# shape's EXPECT names them.
statuses_of() {
  local all k
  all=$(status_of "$1")
  for ((k = 2; k <= $(clients_of "$2"); k++)); do all="$all,$(client_status "$1" "$k")"; done
  echo "$all"
}
knobs_of() { sed -n 's/^metal-vmm: FAULT_SEED=[0-9]* is //p' "$WORK/$1.err" | head -1; }
# The peer's own end, when it let the page go itself (REVIEW-peer.md S1).
peer_end_of() { sed -n 's/^metal-vmm: the first client \(gave up\|vanished\).*/\1/p' "$WORK/$1.err" | head -1; }
# **AN EXCUSE NEEDS ITS FAULT TO HAVE FIRED** (metal-vmm QUEUE 124(e)): the
# faults metal-vmm says took effect (reports.zig `fired`), space-separated
# with a space at each end. A knob the seed drew whose moment never came (a
# reset after the run ended, a cut past the last write) excuses nothing; a
# run that says no fired line had none turned.
fired_of() { echo " $(sed -n 's/^metal-vmm: fired: //p' "$WORK/$1.err" | tail -1 | sed 's/^none$//') "; }
# during_of <run> <k>: the faults that fired while client k's request was
# open (reports.zig `During`), space-separated with a space at each end.
during_of() { echo " $(sed -n "s/^metal-vmm: fired during client $2: //p" "$WORK/$1.err" | tail -1) "; }
broken_of() { sed -n 's/^metal-vmm: coverage: .*, \([0-9]*\) broken).*/\1/p' "$WORK/$1.err" | tail -1; }
# broken_props <run>: the id of each property the run broke, once each, from
# its own coverage lines: a must-hold one (Always, AlwaysOrUnreachable,
# Unreachable) hit with its condition false, as report.py counts them.
broken_props() {
  python3 - "$WORK/$1.cov" <<'PY'
import json, sys
seen = []
for line in open(sys.argv[1], errors="replace"):
    try:
        a = json.loads(line).get("antithesis_assert")
    except ValueError:
        continue
    if a and a.get("display_type") in ("Always", "AlwaysOrUnreachable", "Unreachable") and a.get("hit") and not a.get("condition"):
        if a["id"] not in seen:
            seen.append(a["id"])
print("\n".join(seen))
PY
}
# **THE KERNEL'S OWN DAMAGE CHECK** (gopher.zig, `vol.check` at boot and
# after each request): its properties, which a disk fault that writes damage
# rightly breaks (QUEUE 128).
DAMAGE_PROPS=("fat: at boot, a volume has no damage beyond what a stop leaves" "fat: after a request, a volume has no damage beyond what a stop leaves")

# counted_leak <sound output> <run's stdout> <what> <image>: whether everything fsck
# complains of on the disk is a leftover the kernel says it left there (its
# end summary: "<what>: K clusters left a counted leak, P long-name parts
# left orphaned, F FAT copy writes failed"), each kind held to its count:
# reclaimed clusters no more than K, orphaned long-name parts no more than
# P, FAT copies that differ only where F is at least one (a copy's write
# failed and the next mount mends it; fsck uses the first). Counted when a
# write failed and so did its cleanup, or a later copy's write: honest, and
# on /admin/host, but fsck still finds them. More than counted fails. The
# caller still holds every file the request does not touch to survive whole
# (`untouched`). Echoes what it allowed.
# **A FLOOR AS WELL AS A CEILING** (148's review): K and P are ceilings,
# exact plus what may be live (U clusters and V parts, said after F). What
# the kernel counted exactly landed, so fsck finds at least K - U clusters,
# and at least one orphaned name where P - V parts are exact (fsck says one
# line per name, the kernel counts parts: QUEUE 152 makes that exact).
# Without the floor, an over-count is slack a real leak hides in. The slack
# left is U: a replace whose commit's landing is unknown counts both the
# old chain and the new one as may be live, though one of them is live.
# **A CHAIN PAST ITS SIZE** (148(c)): fsck names the file, says "cluster
# chain length is > N bytes" and "Truncating file to M bytes", and counts
# what it would cut neither in use nor reclaimed. So the clusters past every
# size are exactly the first FAT's taken ones (tools/fat_taken.py) less
# fsck's in-use count less what it reclaimed: X, held to no more than the
# kernel's L ("L clusters past a size", exact plus may be live), and to at
# least one a file. A size past its chain ("chain length is N bytes", no
# ">") is a file cut short, and fails as before.
counted_leak() {
  local n q d k p f u v l t x taken used rest line
  rest=$(sed '1d' "$1" | awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^  \// && line[i+1] ~ /^    File size is [0-9]+ bytes, cluster chain length is > [0-9]+ bytes\.$/ && line[i+2] ~ /^    Truncating file to [0-9]+ bytes\.$/) { i += 2; continue }
        print line[i]
      }
    }' | grep -v "^  Reclaimed [0-9]* unused clusters\? (\|^  Orphaned long file name part \|^    Auto-deleting\.$\|^  FATs differ but appear to be intact\.$\|^    Using first FAT\.$\|^  Leaving filesystem unchanged\.$")
  [ -z "$rest" ] || return 1
  n=$(sed -n -E 's/^  Reclaimed ([0-9]+) unused clusters? \(.*/\1/p' "$1" | head -1)
  q=$(grep -c "^  Orphaned long file name part " "$1")
  d=$(grep -c "^  FATs differ but appear to be intact\.$" "$1")
  t=$(grep -cE "^    File size is [0-9]+ bytes, cluster chain length is > [0-9]+ bytes\.$" "$1")
  # v22's kernel says no FAT copy count: read as none failed.
  line=$(grep -E "^  $3: [0-9]+ clusters left a counted leak, [0-9]+ long-name parts left orphaned" "$2" | tail -1)
  [ -n "$line" ] || return 1
  k=$(echo "$line" | sed -E 's/.*: ([0-9]+) clusters left.*/\1/')
  p=$(echo "$line" | sed -E 's/.*, ([0-9]+) long-name parts.*/\1/')
  f=0
  case "$line" in *" FAT copy writes failed"*) f=$(echo "$line" | sed -E 's/.*, ([0-9]+) FAT copy writes failed.*/\1/') ;; esac
  # v22's and B42's kernels count nothing as may be live: U and V are 0.
  u=0 v=0
  case "$line" in *" may be live"*)
    u=$(echo "$line" | sed -E 's/.*of the clusters and parts, ([0-9]+) and [0-9]+ may be live.*/\1/')
    v=$(echo "$line" | sed -E 's/.*of the clusters and parts, [0-9]+ and ([0-9]+) may be live.*/\1/') ;;
  esac
  # Before 148 a kernel counted no chain past its size: L is 0.
  l=0
  case "$line" in *" clusters past a size"*) l=$(echo "$line" | sed -E 's/.*; ([0-9]+) clusters past a size.*/\1/') ;; esac
  x=0
  if [ "$t" -gt 0 ]; then
    used=$(sed -n -E '1s/^  [0-9]+ files, ([0-9]+)\/[0-9]+ clusters$/\1/p' "$1")
    taken=$("$FAT_TAKEN" "$4") && [ -n "$used" ] || return 1
    x=$((taken - used - ${n:-0}))
    [ "$x" -ge "$t" ] && [ "$x" -le "$l" ] || return 1
  fi
  [ "${n:-0}" -le "$k" ] && [ "${n:-0}" -ge $((k - u)) ] && [ "$q" -le "$p" ] && { [ $((p - v)) = 0 ] || [ "$q" -ge 1 ]; } &&
    { [ "$d" = 0 ] || [ "$f" -ge 1 ]; } && [ "${n:-0}$q$d$t" != "0000" ] || return 1
  echo "${n:-0} of $k clusters ($u may be live), $q of $p parts ($v may be live), $x of $l clusters past a size in $t files, FAT copies $( [ "$d" = 0 ] && echo agree || echo "apart ($f writes failed)")"
}

# lie_lost <disk|volume> <name>: whether that disk's cache lost what it
# held at the cut (metal-vmm QUEUE 122): a lie that cost nothing excuses
# nothing, and an unsound disk is then the guest's own doing.
lie_lost() {
  case "$1" in
    disk) grep -qE "^metal-vmm: disk: a write cache, .*lost [1-9][0-9]* sectors never flushed" "$WORK/$2.err" ;;
    volume) grep -qE "^metal-vmm: volume: .*; the power (cut|failed when the guest stopped and) lost sectors never synchronized" "$WORK/$2.err" ;;
  esac
}

# changed <image>: whether its modification time moved since it was copied.
changed() { [ "$(stat -c %y "$1")" != "$(cat "$1.copied")" ]; }

# answer_excuse <run> <k> <status> <unhurt status> <page> <unhurt page>
# <fired>: what excuses client k's answer differing from the same client's
# unhurt one, comma-separated, or nothing.
answer_excuse() {
  local name="$1" k="$2" status="$3" ustatus="$4" page="$5" upage="$6" fired="$7" excuse=""
  # **A FAULT EXCUSES LESS OF THE PAGE, NEVER ANOTHER ONE** (Steve,
  # 2026-10-08): no answer at all, or the unhurt run's status with its
  # page cut short. Another status (a 404, a 200 where it was a 303) or
  # another page under the same status is a failure, whatever was turned;
  # the one other status excused is a 5xx after a disk fault, below.
  local less=no
  if [ -z "$status" ] || [ "$status" = 0 ]; then less=yes
  elif [ "$status" = "$ustatus" ] && [ -f "$page" ] && [ -f "$upage" ]; then
    local got want
    got=$(wc -c < "$page")
    want=$(wc -c < "$upage")
    [ "$got" -lt "$want" ] && cmp -s -n "$got" "$page" "$upage" && less=yes
  fi
  # **A SERVER THAT SAYS IT FAILED, WHEN ITS DISK DID**: a 5xx is excused
  # by a fault on the disk or the volume, and by nothing else; and only by
  # one that fired while this client's request was open (metal-vmm QUEUE
  # 138(d)). A refusal at boot, or during another client's request, is the
  # very bug class a later 5xx would be: an earlier refusal that breaks
  # later writes.
  case "$status" in 5??)
    local during
    during=$(during_of "$name" "$k")
    for f in DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT DISK_BAD_SECTOR VOLUME_CUT_AFTER VOLUME_SHORT_AT VOLUME_GONE_AT VOLUME_READ_ONLY_AT; do
      case "$during" in *" $f "*) excuse="$excuse${excuse:+, }$f (a $status)" ;; esac
    done ;;
  esac
  if [ $less = yes ]; then
    # The first client's vanishing excuses the others' lesser answers too:
    # the guest serves one connection at a time, so a client that vanished
    # holds the rest behind it. Its reset does not: a reset frees the guest
    # at once, and excusing it would hide a reset that breaks another
    # connection (QUEUE 127(e)).
    for f in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT VOLUME_CUT_AFTER; do
      [ "$f" != PEER_RESET_AT ] || [ "$k" = 1 ] || continue
      case "$fired" in *" $f "*) excuse="$excuse${excuse:+, }$f" ;; esac
    done
    local gone
    gone=$(peer_end_of "$name")
    [ -z "$gone" ] || excuse="$excuse${excuse:+, }the peer $gone"
    # The guest's own word that its stop cut a response: a run with a
    # request limit (the site volume serves one) ends 2 s after it,
    # wherever the client is; a machine with no limit never stops.
    if grep -q '^  let go at the end: .* cut by the stop' "$WORK/$name.out"; then
      excuse="$excuse${excuse:+, }the stop cut it"
    fi
    # **THE REQUEST LIMIT WENT TO ANOTHER CLIENT**: a machine told to
    # serve n requests (the site volume's conf) serves n and stops, so with
    # more clients than that, one a fault slowed may be the one not
    # served. Only when the guest served exactly its limit and the other
    # clients' answers are every one of them: one served and not counted
    # was this client's, and its answer lost (metal-vmm QUEUE 122).
    local limit served others
    limit=$(sed -n -E 's/^  serving ([0-9]+) request\(s\).*/\1/p' "$WORK/$name.out" | head -1)
    served=$(sed -n -E 's/^  served ([0-9]+) request\(s\).*/\1/p' "$WORK/$name.out" | tail -1)
    others=$(sed -n -E 's/^peer ([1-9][0-9]*): [0-9]+, ([0-9]+) of [0-9]+ answers.*/\1 \2/p' "$WORK/$name.out" | awk -v k="$k" '$1 != k { n += $2 } END { print n + 0 }')
    if [ -n "$limit" ] && [ "$limit" = "$served" ] && [ "$others" -gt 0 ] && [ "$others" = "$served" ]; then
      excuse="$excuse${excuse:+, }the request limit went to another client"
    fi
  fi
  echo "$excuse"
}

# verdict <name>: "ok", "differs (allowed: ...)", or "FAIL: ..." for one run
# against the unhurt one.
verdict() {
  local name="$1" u="${2:-unhurt}" sh="${3:-}" why="" exit status knobs broken excuse="" fired c
  exit=$(cat "$WORK/$name.exit")
  status=$(status_of "$name")
  knobs=$(knobs_of "$name")
  fired=$(fired_of "$name")
  broken=$(broken_of "$name")
  if [ "$exit" != "$(cat "$WORK/$u.exit")" ]; then
    # **A CLIENT THAT LEFT BEFORE ITS REQUEST WAS WHOLE IS OWED NOTHING**, and
    # a machine told to serve one request waits for it, idle, until metal-vmm
    # ends the run (exit 1, GuestIdle): long.sh's rough peers allow the same.
    # Only then, and only with no answer given; any other exit fails.
    if [ "$exit" = 1 ] && grep -q '^error: GuestIdle$' "$WORK/$name.err" &&
      { [ -z "$status" ] || [ "$status" = 0 ]; } &&
      { case "$fired" in *" PEER_RESET_AT "* | *" PEER_VANISH_AFTER "*) true ;; *) [ -n "$(peer_end_of "$name")" ] ;; esac; }; then
      excuse="$excuse${excuse:+, }an idle end after the client left"
    else
      why="$why, exit $exit (unhurt: $(cat "$WORK/$u.exit"))"
    fi
  fi
  # **A PROPERTY BROKEN BY THE DAMAGE THE DISK WAS DEALT** (QUEUE 128): the
  # kernel's "no damage" check counts what rot, a torn write, a bad sector or
  # a lying cache's lost writes left, and is right to. Only those
  # properties, and only when such a fault fired; any other break fails, as
  # does one of these with no such fault. The property does not say which
  # disk it found the damage on, so a fault on either disk excuses it.
  local damage_by=""
  if [ "${broken:-0}" != 0 ]; then
    local props other=""
    props=$(broken_props "$name")
    if [ -z "$props" ]; then other=yes
    else
      local p d is
      while IFS= read -r p; do
        is=""
        for d in "${DAMAGE_PROPS[@]}"; do [ "$p" != "$d" ] || is=yes; done
        [ -n "$is" ] || other=yes
      done <<< "$props"
    fi
    if [ -z "$other" ]; then
      for f in DISK_ROT DISK_TEAR DISK_BAD_SECTOR; do
        case "$fired" in *" $f "*) damage_by="$damage_by${damage_by:+, }$f" ;; esac
      done
      case " $knobs" in *" DISK_CACHE=lie"*) ! lie_lost disk "$name" || damage_by="$damage_by${damage_by:+, }DISK_CACHE=lie" ;; esac
      case " $knobs" in *" VOLUME_CACHE=lie"*) ! lie_lost volume "$name" || damage_by="$damage_by${damage_by:+, }VOLUME_CACHE=lie" ;; esac
    fi
    [ -n "$damage_by" ] || why="$why, $broken coverage properties broken"
  fi
  # metal-vmm's own fault: a frame lost that no knob asked for.
  ! grep -q "^metal-vmm: the wire was full and pushed out .*, which it never sends again" "$WORK/$name.err" || why="$why, the wire pushed out the peer's frames, which it never sends again"
  # A disk whose power was cut mid-write may hold what a stop leaves
  # (sound.sh, `STOP_LEAVES`), and nothing else. **ONE POWER STOPS THE WHOLE
  # MACHINE** (metal-vmm QUEUE 124(c)): a cut on either disk stops the guest
  # mid-write on the other too, so either cut lets both hold a stop's
  # leftovers. What a stop leaves never covers a file the request does not
  # touch: that must survive whole (`untouched`, QUEUE 124(b)), checked
  # after every cut, not only one fsck found leftovers after: a lost file's
  # remains can be ones fsck says nothing of (QUEUE 127).
  local disk_cut="" volume_cut=""
  grep -qE "^metal-vmm: the power was cut (in the guest's write [0-9]+:|after the guest's write [0-9]+ \(sector)" "$WORK/$name.err" && disk_cut=1
  grep -qE "^metal-vmm: the power was cut after the guest's write [0-9]+ to the volume" "$WORK/$name.err" && volume_cut=1
  [ -z "$disk_cut$volume_cut" ] || { disk_cut=1; volume_cut=1; }
  # **A DISK THAT LIED ABOUT ITS CACHE, THEN LOST ITS POWER** (Steve,
  # 2026-10-09): it said it writes through, so nothing was ever flushed, and
  # the cut kept what it held in an order of its own. No driver can defend
  # against that, so it excuses an unsound disk, as the durability judge
  # excuses a lost write; only with both the lie and a cut (mid-write, or
  # at the end, VOLUME_CUT_AT_EXIT). Kept apart from `excuse`, which the
  # page's judgement reads: a lie excuses the disk, never the page.
  local unsound="" exit_cut=""
  [ -z "$damage_by" ] || unsound="$damage_by ($(broken_props "$name" | sed ':a;N;$!ba;s/\n/; /'))"
  # Noted, for the merge below: these breaks are not the report's failure.
  [ -z "$damage_by" ] || : > "$WORK/$name.damage_excused"
  grep -q "^metal-vmm: the power failed when the guest stopped" "$WORK/$name.err" && exit_cut=1
  local site
  site=$(site_of "$sh")
  if changed "$WORK/$name.img" && ! cmp -s "$WORK/$name.img" "$site"; then
    if STOP_LEAVES="$disk_cut" "$SOUND" "$WORK/$name.img" > "$WORK/$name.sound" 2>&1; then
      { grep -q "sound but for what a stop leaves" "$WORK/$name.sound" || [ -n "$disk_cut$exit_cut" ]; } && ! "$UNTOUCHED" "$site" "$WORK/$u.img" "$WORK/$name.img" > "$WORK/$name.untouched" 2>&1 &&
        why="$why, the volume lost a file the request does not touch ($(head -1 "$WORK/$name.untouched" | sed 's/^ *//'))"
    else
      case " $knobs" in
        *" DISK_CACHE=lie"*) [ -n "$disk_cut$exit_cut" ] && lie_lost disk "$name" && unsound="$unsound${unsound:+, }DISK_CACHE=lie (the volume left unsound)" || why="$why, the volume is not sound" ;;
        *) if c=$(counted_leak "$WORK/$name.sound" "$WORK/$name.out" "the boot disk" "$WORK/$name.img"); then
             unsound="$unsound${unsound:+, }a leak the kernel counted (the boot disk: $c)"
             "$UNTOUCHED" "$site" "$WORK/$u.img" "$WORK/$name.img" > "$WORK/$name.untouched" 2>&1 ||
               why="$why, the volume lost a file the request does not touch ($(head -1 "$WORK/$name.untouched" | sed 's/^ *//'))"
           else why="$why, the volume is not sound"; fi ;;
      esac
    fi
  fi
  if [ -n "${VOLUME_SITE:-}" ] && changed "$WORK/$name.vol" && ! cmp -s "$WORK/$name.vol" "$VOLUME_SITE"; then
    if STOP_LEAVES="$volume_cut" "$SOUND" "$WORK/$name.vol" > "$WORK/$name.vsound" 2>&1; then
      { grep -q "sound but for what a stop leaves" "$WORK/$name.vsound" || [ -n "$volume_cut$exit_cut" ]; } && ! "$UNTOUCHED" "$VOLUME_SITE" "$WORK/$u.vol" "$WORK/$name.vol" > "$WORK/$name.vuntouched" 2>&1 &&
        why="$why, the attached volume lost a file the request does not touch ($(head -1 "$WORK/$name.vuntouched" | sed 's/^ *//'))"
    else
      case " $knobs" in
        *" VOLUME_CACHE=lie"*) [ -n "$volume_cut$exit_cut" ] && lie_lost volume "$name" && unsound="$unsound${unsound:+, }VOLUME_CACHE=lie (the attached volume left unsound)" || why="$why, the attached volume is not sound" ;;
        *) if c=$(counted_leak "$WORK/$name.vsound" "$WORK/$name.out" "the volume" "$WORK/$name.vol"); then
             unsound="$unsound${unsound:+, }a leak the kernel counted (the attached volume: $c)"
             "$UNTOUCHED" "$VOLUME_SITE" "$WORK/$u.vol" "$WORK/$name.vol" > "$WORK/$name.vuntouched" 2>&1 ||
               why="$why, the attached volume lost a file the request does not touch ($(head -1 "$WORK/$name.vuntouched" | sed 's/^ *//'))"
           else why="$why, the attached volume is not sound"; fi ;;
      esac
    fi
  fi
  # **A DURABLE SHAPE KEEPS WHAT IT WAS TOLD IT KEPT** (QUEUE 125), judged
  # beside its page: told TOLD and its MARK not in the read-back fails, as a
  # durability sweep's does, but where a lying cache's power took what it
  # held, or a SYNCHRONIZE CACHE failed; those excuse the write, never the
  # page.
  if [ -n "$(read_of "$sh")" ]; then
    local shape_read
    shape_read=$(cat "$WORK/$name.readstatus")
    # **A READ-BACK THAT IS NOT 200** (QUEUE 127(c), (f)): a run not told
    # TOLD may have written nothing, and its read-back then answers as the
    # pristine volume's did (`GET /game/sessions/2/actions` is a 404 until
    # session 2 is made). A 5xx is the volume's state speaking, excused when
    # a lying cache's power took what it held, as a lost write is. Any other
    # read-back without a page fails.
    # Told TOLD, a read-back that answers as the pristine volume's did is
    # the write not on the volume (seed 201 of 2026-10-10: a new session a
    # lying cache's power took, read back 404), judged as a MARK not kept.
    local as_pristine="" told
    told=$(told_of "$name" "$sh")
    [ "$shape_read" != "200" ] && [ "$shape_read" = "$(cat "$WORK/pristine-$sh.readstatus")" ] && as_pristine=1
    if [ -n "$as_pristine" ] && [ "$told" != "${SHAPE_TOLD[$sh]}" ]; then
      :
    elif [ "$shape_read" != "200" ] && [ -z "$as_pristine" ]; then
      case "$shape_read" in
        5??) case " $knobs" in *" VOLUME_CACHE=lie"*) lie_lost volume "$name" && unsound="$unsound${unsound:+, }VOLUME_CACHE=lie (the read-back failed, $shape_read)" ;; esac ;;
      esac
      case "$unsound" in *"(the read-back failed, $shape_read)"*) ;; *) why="$why, the read-back boot got no page (status ${shape_read:-none})" ;; esac
    elif [ "$told" = "${SHAPE_TOLD[$sh]}" ] && { [ -n "$as_pristine" ] || ! kept "$name" "${SHAPE_MARK[$sh]}"; }; then
      local lost=""
      case " $knobs" in *" VOLUME_CACHE=lie"*) ! lie_lost volume "$name" || lost="VOLUME_CACHE=lie (the write lost)" ;; esac
      # A failed SYNCHRONIZE loses nothing by itself: only a power that then
      # took what the cache held (lie_lost reads that line, lie or not).
      case "$fired" in *" VOLUME_SYNC_FAIL "*) ! lie_lost volume "$name" || lost="$lost${lost:+, }VOLUME_SYNC_FAIL (the write lost)" ;; esac
      if [ -n "$lost" ]; then unsound="$unsound${unsound:+, }$lost"
      else why="$why, told ${SHAPE_TOLD[$sh]} and the write is not on the volume"; fi
    fi
  fi
  if [ -n "$DURABLE" ]; then
    local read_status
    read_status=$(cat "$WORK/$name.readstatus")
    # Not 200: as a durable shape's (QUEUE 127(c), (f)).
    local as_pristine=""
    [ "$read_status" != "200" ] && [ "$read_status" = "$(cat "$WORK/pristine.readstatus")" ] && as_pristine=1
    if [ -n "$as_pristine" ] && [ "$status" != "$TOLD" ]; then
      :
    elif [ "$read_status" != "200" ] && [ -z "$as_pristine" ]; then
      case "$read_status" in
        5??) case " $knobs" in *" VOLUME_CACHE=lie"*) lie_lost volume "$name" && excuse="$excuse${excuse:+, }VOLUME_CACHE=lie (the read-back failed, $read_status)" ;; esac ;;
      esac
      case "$excuse" in *"(the read-back failed, $read_status)"*) ;; *) why="$why, the read-back boot got no page (status ${read_status:-none})" ;; esac
    elif [ "$status" = "$TOLD" ] && { [ -n "$as_pristine" ] || ! kept "$name"; }; then
      # A lie excuses a lost write only when the power took what the cache
      # held; a SYNCHRONIZE failure, only when one failed.
      case " $knobs" in *" VOLUME_CACHE=lie"*) ! lie_lost volume "$name" || excuse="VOLUME_CACHE=lie" ;; esac
      case "$fired" in *" VOLUME_SYNC_FAIL "*) ! lie_lost volume "$name" || excuse="$excuse${excuse:+, }VOLUME_SYNC_FAIL" ;; esac
      [ -n "$excuse" ] || why="$why, told $TOLD and the write is not on the volume"
    fi
    if [ -n "$why" ]; then echo "FAIL: ${why#, }"
    elif [ -n "$excuse" ]; then echo "lost (allowed: $excuse${unsound:+, $unsound})"
    elif [ -n "$unsound" ]; then echo "allowed: unsound ($unsound)"
    elif [ "$status" = "$TOLD" ]; then echo "ok, kept"
    elif kept "$name"; then echo "ok, not told, kept"
    else echo "ok, not told, not kept"; fi
    return
  fi
  # **EVERY CLIENT, AGAINST THE SAME CLIENT UNHURT** (metal-vmm QUEUE 126).
  # In turn, a client asks after the one before was answered, and may ask
  # for what that one should have made: once one differs so that its write
  # is in doubt (no answer, a 5xx, another status; QUEUE 134(g)), a later
  # one may also answer what the shape's UNMADE names (a 404: no such
  # session), and nothing else its own faults do not excuse (QUEUE 127(d)). Not in turn,
  # or before any differs, each is judged alone.
  local k ks us cex differed=""
  for ((k = 1; k <= $(clients_of "$sh"); k++)); do
    if [ "$k" = 1 ]; then ks="$status"; us=$(status_of "$u"); else ks=$(client_status "$name" "$k"); us=$(client_status "$u" "$k"); fi
    [ "$ks" != "$us" ] || ! cmp -s "$(client_page "$name" "$k")" "$(client_page "$u" "$k")" || continue
    cex=""
    if [ -n "$differed" ] && in_turn_of "$sh" && [ -n "$ks" ]; then
      case ",${sh:+${SHAPE_UNMADE[$sh]:-}}," in *",$ks,"*) cex="a $ks as UNMADE allows, after client $differed's answer differed" ;; esac
    fi
    [ -n "$cex" ] || cex=$(answer_excuse "$name" "$k" "$ks" "$us" "$(client_page "$name" "$k")" "$(client_page "$u" "$k")" "$fired")
    # **ONLY A DIFFERENCE THAT LEAVES ITS WRITE IN DOUBT** (QUEUE 134(g)):
    # no answer, a 5xx, or a status not its unhurt one. A page cut short
    # under its own status says the write was made: what came after may
    # not answer as if it were not.
    if [ -z "$differed" ]; then
      case "$ks" in "" | 0 | 5??) differed="$k" ;; *) [ "$ks" = "$us" ] || differed="$k" ;; esac
    fi
    if [ "$k" = 1 ]; then
      if [ -n "$cex" ]; then excuse="$excuse${excuse:+, }$cex"; else why="$why, not the page (status ${status:-none})"; fi
    elif [ -n "$cex" ]; then excuse="$excuse${excuse:+, }client $k: $cex"
    else why="$why, client $k: not its page (status ${ks:-none}; unhurt: ${us:-none})"; fi
  done
  if [ -n "$why" ]; then echo "FAIL: ${why#, }"
  elif [ -n "$excuse$unsound" ]; then echo "differs (allowed: $excuse${excuse:+${unsound:+, }}$unsound)"
  else echo "ok"; fi
}

# **THE SETUP** (SHAPES' `setup`): its requests sent in turn, unhurt, to one
# copy of VOLUME_SITE, which every run below then starts from.
if [ -n "${SHAPES:-}" ] && [ -f "$SHAPES/setup" ]; then
  [ -n "${VOLUME_SITE:-}" ] || cannot_judge "a setup needs VOLUME_SITE=<image>"
  cp "$VOLUME_SITE" "$WORK/setup.vol"
  while IFS= read -r req; do
    req="${req%%#*}"; req="${req%"${req##*[![:space:]]}"}"
    [ -n "$req" ] || continue
    cp "$SITE" "$WORK/setup.img"
    env PEER_REQUEST="$SHAPES/$req" VOLUME="$WORK/setup.vol" \
      timeout "$RUN_TIMEOUT" "$VMM" "$KERNEL" "$WORK/setup.img" "" / > "$WORK/setup.out" 2> "$WORK/setup.err"
    echo "setup: $req, $(sed -n -E 's/^peer: ([0-9]+)( "|, [0-9]+ bytes$).*/status \1/p' "$WORK/setup.out" | head -1)"
  done < "$SHAPES/setup"
  rm -f "$WORK/setup.img"
  VOLUME_SITE="$WORK/setup.vol"
fi

# Each shape's unhurt run; then the first's is "unhurt" for what follows.
for n in "${SHAPE_NAMES[@]}"; do
  u=$(unhurt_of "$n")
  # shellcheck disable=SC2086
  # **A SITE THAT SERVES EVERY CLIENT** (QUEUE 127(h)): the site's own
  # limit (`requests = 1`) is what ends a run, and would serve a shape of n
  # clients its first alone. Such a shape boots from a copy saying
  # clients x asks.
  need=$(( $(clients_of "$n") * $(asks_of "$n") ))
  if [ "$need" -gt 1 ]; then
    "$SITE_REQUESTS" "$SITE" "$WORK/site-${n:-none}.img" "$need" > "$WORK/site-${n:-none}.out" 2>&1 ||
      { echo "${n:+shape $n: }could not raise the site's requests to $need:"; sed 's/^/  /' "$WORK/site-${n:-none}.out"; cannot_judge; }
    echo "${n:+shape $n: }the site raised to $need requests ($(tail -1 "$WORK/site-${n:-none}.out"))"
  fi
  # shellcheck disable=SC2086
  RUN_SITE=$(site_of "$n") run "$u" $(shape_env "$n")
  # **A KERNEL THAT REPORTS NO PROPERTY JUDGES NOTHING** (2026-10-09): one
  # built without -Dcoverage records its properties and never says them, so
  # "no property broken" would hold of every run, vacuously, all night.
  # Stopped here, before any seed.
  if ! grep -qE '^metal-vmm: coverage: [0-9]+ of [1-9][0-9]* properties' "$WORK/$u.err"; then
    echo "$KERNEL reported no coverage property in its unhurt run: it was built without -Dcoverage, or the run ended before it said any. Nothing can be judged."
    echo "  build one: (cd ~/showell_repos/gopher-metal && zig build gopher -Dcoverage), and copy probe/gopher.elf aside: gates.sh wants the release build there"
    cannot_judge
  fi
  # **EVERY CLIENT'S UNHURT PAGE** (QUEUE 126): each client past the first
  # is held to its own, so each must have one.
  for ((k = 2; k <= $(clients_of "$n"); k++)); do
    if [ -z "$(client_status "$u" "$k")" ] || [ ! -f "$(client_page "$u" "$k")" ]; then
      echo "${n:+shape $n: }the unhurt run's client $k got $([ -n "$(client_status "$u" "$k")" ] && echo "status $(client_status "$u" "$k") and no page" || echo "no answer"): nothing can be judged; see $WORK/$u.out"
      cannot_judge
    fi
  done
  if [ -n "$n" ]; then
    st=$(status_of "$u")
    sts=$(statuses_of "$u" "$n")
    echo "shape $n: unhurt status ${sts:-none}, $([ -f "$WORK/$u.body" ] && wc -c < "$WORK/$u.body" || echo no) bytes (${SHAPE_ENV[$n]})"
    if [ -n "${SHAPE_EXPECT[$n]:-}" ] && [ "$sts" != "${SHAPE_EXPECT[$n]}" ]; then
      echo "shape $n: its unhurt run answered ${sts:-nothing}, not ${SHAPE_EXPECT[$n]}: nothing can be judged; see $WORK/$u.out"
      cannot_judge
    fi
    [ -f "$WORK/unhurt.exit" ] || for x in exit out err body cov; do [ ! -f "$WORK/$u.$x" ] || cp "$WORK/$u.$x" "$WORK/unhurt.$x"; done
    # **A DURABLE SHAPE'S RECIPE MUST HOLD** (QUEUE 125): the pristine
    # volume without its MARK, and its unhurt run told TOLD and keeping it.
    if [ -n "$(read_of "$n")" ]; then
      read_back "pristine-$n" "$VOLUME_SITE" "${SHAPE_READ[$n]}"
      read_back "$u" "" "${SHAPE_READ[$n]}"
      # A seed's read-back is compared with the pristine one's status: with
      # none, a read-back that got no answer would look like it.
      [ -s "$WORK/pristine-$n.readstatus" ] || cannot_judge "shape $n: the pristine volume's read-back got no answer: nothing can be judged"
      ! kept "pristine-$n" "${SHAPE_MARK[$n]}" || cannot_judge "shape $n: the pristine volume's read-back already holds \"${SHAPE_MARK[$n]}\": nothing can be judged"
      st=$(told_of "$u" "$n")
      if [ "$st" != "${SHAPE_TOLD[$n]}" ] || ! kept "$u" "${SHAPE_MARK[$n]}"; then
        echo "shape $n: its unhurt run was told ${st:-nothing} and its read-back $(kept "$u" "${SHAPE_MARK[$n]}" && echo holds || echo lacks) \"${SHAPE_MARK[$n]}\" (TOLD=${SHAPE_TOLD[$n]}): nothing can be judged"
        cannot_judge
      fi
      echo "shape $n: each seed is read back with $(basename "${SHAPE_READ[$n]}") for \"${SHAPE_MARK[$n]}\" when told ${SHAPE_TOLD[$n]}"
    fi
  fi
done
unhurt_status=$(status_of unhurt)
if [ -n "$DURABLE" ]; then
  read_back pristine "$VOLUME_SITE"
  read_back unhurt
  [ -s "$WORK/pristine.readstatus" ] || cannot_judge "the pristine volume's read-back got no answer: nothing can be judged"
  ! kept pristine || cannot_judge "the pristine volume already holds MARK: nothing can be judged"
  if [ "$unhurt_status" != "$TOLD" ] || ! kept unhurt; then
    echo "the unhurt post was told ${unhurt_status:-nothing} and its read-back $(kept unhurt && echo holds || echo lacks) MARK: nothing can be judged"
    cannot_judge
  fi
  echo "durability: each seed posts $POST, then reads back $READ_BACK for \"$MARK\""
fi
if [ -z "$unhurt_status" ] || [ ! -f "$WORK/unhurt.body" ]; then
  echo "the unhurt run got $([ -n "$unhurt_status" ] && echo "status $unhurt_status and no page" || echo "no answer") (exit $(cat "$WORK/unhurt.exit")): nothing can be judged; see its log:"
  tail -5 "$WORK/unhurt.out" "$WORK/unhurt.err"
  cannot_judge
fi
echo "unhurt: exit $(cat "$WORK/unhurt.exit"), status $unhurt_status, $(wc -c < "$WORK/unhurt.body") bytes of $PATH_WANTED"
printf '%-6s %-14s %-4s %-6s %-8s %-40s %s\n' seed shape exit status bytes verdict knobs

failing=""
# **THE SEEDS, `JOBS` AT A TIME** (2 by default: this box's two cores),
# then judged and printed in order. Each run is a function of its seed
# alone, so running them side by side changes nothing but the wall time.
JOBS="${JOBS:-2}"
seed="$FIRST"
while [ "$seed" -le "$LAST" ]; do
  # shellcheck disable=SC2086
  sh=$(shape_of "$seed")
  # shellcheck disable=SC2086
  ( RUN_SITE=$(site_of "$sh") run "seed$seed" FAULT_SEED="$seed" $(shape_env "$sh"); [ -z "$DURABLE" ] || read_back "seed$seed"
    [ -z "$(read_of "$sh")" ] || read_back "seed$seed" "" "${SHAPE_READ[$sh]}" ) &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  seed=$((seed + 1))
done
wait

ok=0
allowed=0
seed="$FIRST"
while [ "$seed" -le "$LAST" ]; do
  v=$(verdict "seed$seed" "$(unhurt_of "$(shape_of "$seed")")" "$(shape_of "$seed")")
  case "$v" in
    ok*) ok=$((ok + 1)) ;;
    differs* | lost* | allowed*) allowed=$((allowed + 1)) ;;
    *) failing="$failing $seed"
       # Kept for reading after the sweep (`KEEP_FAILED=<dir>`): the run's
       # stdout, stderr, page and coverage; its images too, if it wrote them.
       if [ -n "${KEEP_FAILED:-}" ]; then
         mkdir -p "$KEEP_FAILED/seed$seed"
         cp "$WORK/seed$seed".* "$KEEP_FAILED/seed$seed/" 2>/dev/null
       fi ;;
  esac
  printf '%-6s %-14s %-4s %-6s %-8s %-40s %s\n' "$seed" "$(shape_of "$seed")" "$(cat "$WORK/seed$seed.exit")" "$(status_of "seed$seed")" \
    "$([ -f "$WORK/seed$seed.body" ] && wc -c < "$WORK/seed$seed.body" || echo none)" "$v" "$(knobs_of "seed$seed")"
  seed=$((seed + 1))
done

# **A BREAK THE DAMAGE DEALT EXCUSES IS NOT THE REPORT'S FAILURE** (QUEUE
# 128): such a seed's false "no damage" events are left out of the merge,
# and said; its own coverage file keeps them (KEEP).
excused_damage=""
for name in $(for n in "${SHAPE_NAMES[@]}"; do unhurt_of "$n"; done) $(seq -f "seed%g" "$FIRST" "$LAST"); do
  [ -f "$WORK/$name.cov" ] || continue
  if [ -f "$WORK/$name.damage_excused" ]; then
    excused_damage="$excused_damage ${name#seed}"
    python3 - "$WORK/$name.cov" "${DAMAGE_PROPS[@]}" >> "$COVERAGE" <<'PY'
import json, sys
props = set(sys.argv[2:])
for line in open(sys.argv[1], errors="replace"):
    try:
        a = json.loads(line).get("antithesis_assert")
    except ValueError:
        a = None
    if a and a.get("id") in props and a.get("hit") and not a.get("condition"):
        continue
    sys.stdout.write(line)
PY
  else
    cat "$WORK/$name.cov" >> "$COVERAGE"
  fi
done

echo
echo "coverage over the sweep:"
[ -z "$excused_damage" ] || echo "the kernel's \"no damage\" breaks left out of the merged report, each excused by the damage its seed was dealt:$excused_damage"
merged=0
if [ -n "${FLOOR:-}" ]; then python3 "$REPORT" "$COVERAGE" --floor "$FLOOR" || merged=1
else python3 "$REPORT" "$COVERAGE" || merged=1; fi

echo
total=$((LAST - FIRST + 1))
if [ -n "$DURABLE" ]; then
  echo "$total seeds: $ok ok, $allowed lost as their faults allow, $(echo $failing | wc -w) failed"
else
  echo "$total seeds: $ok ok, $allowed differ as their faults allow, $(echo $failing | wc -w) failed"
fi
for s in $failing; do
  echo "  FAULT_SEED=$s: $(verdict "seed$s" "$(unhurt_of "$(shape_of "$s")")" "$(shape_of "$s")")"
  if [ -n "$DURABLE" ]; then
    echo "    repeat it: $(knobs_of "seed$s") PEER_REQUEST=$POST VOLUME=<a copy of $VOLUME_SITE> VOLUME_CUT_AT_EXIT=1 TRANSPORT=$TRANSPORT $VMM $KERNEL <disk> \"\" /; then read back $READ_BACK"
  else
    sh=$(shape_of "$s")
    echo "    repeat it: $(knobs_of "seed$s")${PEER_REQUEST:+ PEER_REQUEST=$PEER_REQUEST}${sh:+ $(shape_env "$sh")}${VOLUME_SITE:+ VOLUME=<a copy of the volume${SHAPES:+, after the setup}>} TRANSPORT=$TRANSPORT $VMM $KERNEL <a copy of $([ "$(site_of "$sh")" = "$SITE" ] && echo "the site" || echo "the site, its requests raised by tools/site_requests.py to $(( $(clients_of "$sh") * $(asks_of "$sh") ))")> \"\" $PATH_WANTED$([ -z "$(read_of "$sh")" ] || echo "; then read back ${SHAPE_READ[$sh]} for \"${SHAPE_MARK[$sh]}\"")"
  fi
done
# **FOR A PROGRAM TO READ** (metal-vmm QUEUE 135): the failing seeds, one
# line, always last but for nothing; plants.sh and nightly.sh read this, not
# the table above.
echo "FAILED_SEEDS:$(for s in $failing; do printf ' %s' "$s"; done)"
[ -z "$failing" ] && [ $merged = 0 ]
