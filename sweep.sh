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
#     property stops the sweep before any seed, since it would judge none;
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
#     nothing (metal-vmm QUEUE 124(e)). A cut volume must still be sound: that is FAT's crash
#     consistency, measured.
#
# Every run's coverage goes to one JSONL, judged at the end by
# zig-coverage-sdk's tools/report.py, which names each run by its seed (with
# FLOOR=<file> if set). The sweep ends with the failing seeds, each as
# the knobs that repeat it without the seed. It exits 1 if any seed failed
# or the merge did.
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
# made): then a client's answer may differ in any way once an earlier
# client's did ("client 1's answer differed first"), and never otherwise. **A WRITE SHAPE MAY CARRY ITS READ-BACK** (metal-vmm QUEUE 125):
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
# Environment: GUESTS, SITE and PATH_WANTED (default /) as rest.sh has them;
# TRANSPORT (default pci, the machine that rests); FLOOR; RUN_TIMEOUT;
# JOBS (2: runs side by side); KEEP_FAILED=<dir>: a failing seed's files kept
# (seconds, default 300); KEEP=<dir> keeps every run's log, page and the
# coverage JSONL there. VMM, REPORT and SOUND name the programs, for a test;
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
[ -n "${FAT_READ:-}" ] || [ ! -f "$GUESTS/../tools/fat16_read.py" ] || export FAT_READ="$GUESTS/../tools/fat16_read.py"
export TRANSPORT="${TRANSPORT:-pci}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
if [ -n "${KEEP:-}" ]; then WORK="$KEEP"; mkdir -p "$WORK"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$REPORT" ] || { echo "no $REPORT; set COVERAGE_SDK=<zig-coverage-sdk checkout>"; exit 1; }
[ -f "$KERNEL" ] || { echo "no $KERNEL"; exit 1; }
[ -f "$SITE" ] || { echo "no volume at $SITE; set SITE=<image>"; exit 1; }
# **THE CHECK A CUT NEEDS, READY BEFORE ANY SEED** (QUEUE 127(a)): a missing
# untouched.py or FAT reader would fail every cut seed with stop leftovers
# as "lost a file", all night. Exit 2: nothing can be judged, and a night
# stops.
"$UNTOUCHED" --ready > "$WORK/untouched.ready" 2>&1 || { echo "$UNTOUCHED --ready failed: a cut's leftovers could not be judged:"; sed 's/^/  /' "$WORK/untouched.ready"; exit 2; }
DURABLE=""
if [ -n "${POST:-}" ]; then
  [ -f "$POST" ] || { echo "no request at POST=$POST"; exit 1; }
  [ -n "${READ_BACK:-}" ] && [ -n "${MARK:-}" ] || { echo "POST needs READ_BACK=<path> and MARK=<text>"; exit 1; }
  [ -n "${VOLUME_SITE:-}" ] || { echo "POST needs VOLUME_SITE=<image>: the message is kept on the volume"; exit 1; }
  DURABLE=yes
fi
TOLD="${TOLD:-303}"
COVERAGE="$WORK/coverage.jsonl"
: > "$COVERAGE"

# The shapes: their names, and each one's settings as VAR=value words, the
# request files made absolute. No SHAPES is one shape, named "", with none.
SHAPE_NAMES=("")
declare -A SHAPE_ENV=() SHAPE_EXPECT=() SHAPE_READ=() SHAPE_MARK=() SHAPE_TOLD=()
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
if [ -n "${SHAPES:-}" ]; then
  [ -d "$SHAPES" ] || { echo "no folder at SHAPES=$SHAPES"; exit 1; }
  [ -z "$DURABLE" ] || { echo "SHAPES and POST are two sweeps; choose one"; exit 1; }
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
        PEER_REQUEST=*)
          files=""
          IFS=, read -ra parts <<< "${line#PEER_REQUEST=}"
          for part in "${parts[@]}"; do
            [ -f "$SHAPES/$part" ] || { echo "shape $n: no request $SHAPES/$part"; exit 1; }
            files="$files${files:+,}$SHAPES/$part"
          done
          words="$words PEER_REQUEST=$files" ;;
        *=*) words="$words $line" ;;
        *) echo "shape $n: not VAR=value: $line"; exit 1 ;;
      esac
    done < "$f"
    SHAPE_ENV[$n]="${words# }"
    # **EVERY SHAPE SAYS WHAT ITS UNHURT RUN MUST ANSWER** (metal-vmm QUEUE
    # 122): with none, a shape gone stale (a cookie expired, a 500) is every
    # seed's baseline, and every seed that fails as it does is "ok".
    [ -n "${SHAPE_EXPECT[$n]:-}" ] || { echo "shape $n: no EXPECT=<status>: its unhurt run is held to nothing, so nothing can be judged"; exit 2; }
    # One status a client (QUEUE 126): a client held to nothing would judge
    # every seed against an answer gone stale.
    want=$(clients_of "$n")
    IFS=, read -ra statuses <<< "${SHAPE_EXPECT[$n]}"
    [ "${#statuses[@]}" = "$want" ] || { echo "shape $n: EXPECT names ${#statuses[@]} status(es) for $want client(s): each client's unhurt answer must be held to one (EXPECT=303,204 for two), so nothing can be judged"; exit 2; }
    if [ -n "${SHAPE_READ[$n]:-}" ]; then
      [ -n "${SHAPE_MARK[$n]:-}" ] || { echo "shape $n: READ_BACK needs MARK=<text>"; exit 1; }
      [ -n "${VOLUME_SITE:-}" ] || { echo "shape $n: READ_BACK needs VOLUME_SITE=<image>: the write is kept on the volume"; exit 1; }
      SHAPE_TOLD[$n]="${SHAPE_TOLD[$n]:-${SHAPE_EXPECT[$n]%%,*}}"
      # Each write cache loses what was never synchronized when the guest
      # stops, as in a durability sweep.
      SHAPE_ENV[$n]="${SHAPE_ENV[$n]}${SHAPE_ENV[$n]:+ }VOLUME_CUT_AT_EXIT=1"
    fi
  done
  [ ${#SHAPE_NAMES[@]} -gt 0 ] || { echo "no *.shape in $SHAPES"; exit 1; }
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
  cp "$SITE" "$WORK/$name.img"
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
broken_of() { sed -n 's/^metal-vmm: coverage: .*, \([0-9]*\) broken).*/\1/p' "$WORK/$1.err" | tail -1; }

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
  # by a fault on the disk or the volume, and by nothing else.
  case "$status" in 5??)
    for f in DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT DISK_BAD_SECTOR VOLUME_CUT_AFTER VOLUME_SHORT_AT VOLUME_GONE_AT VOLUME_READ_ONLY_AT; do
      case "$fired" in *" $f "*) excuse="$excuse${excuse:+, }$f (a $status)" ;; esac
    done ;;
  esac
  if [ $less = yes ]; then
    # The first client's own faults excuse the others' lesser answers too:
    # the guest serves one connection at a time, so a client that vanished
    # holds the rest behind it.
    for f in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT VOLUME_CUT_AFTER; do
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
  local name="$1" u="${2:-unhurt}" sh="${3:-}" why="" exit status knobs broken excuse="" fired
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
  [ "${broken:-0}" = 0 ] || why="$why, $broken coverage properties broken"
  # metal-vmm's own fault: a frame lost that no knob asked for.
  ! grep -q "^metal-vmm: the wire was full and pushed out .*, which it never sends again" "$WORK/$name.err" || why="$why, the wire pushed out the peer's frames, which it never sends again"
  # A disk whose power was cut mid-write may hold what a stop leaves
  # (sound.sh, `STOP_LEAVES`), and nothing else. **ONE POWER STOPS THE WHOLE
  # MACHINE** (metal-vmm QUEUE 124(c)): a cut on either disk stops the guest
  # mid-write on the other too, so either cut lets both hold a stop's
  # leftovers. What a stop leaves never covers a file the request does not
  # touch: that must survive whole (`untouched`, QUEUE 124(b)).
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
  grep -q "^metal-vmm: the power failed when the guest stopped" "$WORK/$name.err" && exit_cut=1
  if changed "$WORK/$name.img" && ! cmp -s "$WORK/$name.img" "$SITE"; then
    if STOP_LEAVES="$disk_cut" "$SOUND" "$WORK/$name.img" > "$WORK/$name.sound" 2>&1; then
      grep -q "sound but for what a stop leaves" "$WORK/$name.sound" && ! "$UNTOUCHED" "$SITE" "$WORK/$u.img" "$WORK/$name.img" > "$WORK/$name.untouched" 2>&1 &&
        why="$why, the volume lost a file the request does not touch ($(head -1 "$WORK/$name.untouched" | sed 's/^ *//'))"
    else
      case " $knobs" in
        *" DISK_CACHE=lie"*) [ -n "$disk_cut$exit_cut" ] && lie_lost disk "$name" && unsound="$unsound${unsound:+, }DISK_CACHE=lie (the volume left unsound)" || why="$why, the volume is not sound" ;;
        *) why="$why, the volume is not sound" ;;
      esac
    fi
  fi
  if [ -n "${VOLUME_SITE:-}" ] && changed "$WORK/$name.vol" && ! cmp -s "$WORK/$name.vol" "$VOLUME_SITE"; then
    if STOP_LEAVES="$volume_cut" "$SOUND" "$WORK/$name.vol" > "$WORK/$name.vsound" 2>&1; then
      grep -q "sound but for what a stop leaves" "$WORK/$name.vsound" && ! "$UNTOUCHED" "$VOLUME_SITE" "$WORK/$u.vol" "$WORK/$name.vol" > "$WORK/$name.vuntouched" 2>&1 &&
        why="$why, the attached volume lost a file the request does not touch ($(head -1 "$WORK/$name.vuntouched" | sed 's/^ *//'))"
    else
      case " $knobs" in
        *" VOLUME_CACHE=lie"*) [ -n "$volume_cut$exit_cut" ] && lie_lost volume "$name" && unsound="$unsound${unsound:+, }VOLUME_CACHE=lie (the attached volume left unsound)" || why="$why, the attached volume is not sound" ;;
        *) why="$why, the attached volume is not sound" ;;
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
    if [ "$shape_read" != "200" ] && [ "$status" != "${SHAPE_TOLD[$sh]}" ] && [ "$shape_read" = "$(cat "$WORK/pristine-$sh.readstatus")" ]; then
      :
    elif [ "$shape_read" != "200" ]; then
      case "$shape_read" in
        5??) case " $knobs" in *" VOLUME_CACHE=lie"*) lie_lost volume "$name" && unsound="$unsound${unsound:+, }VOLUME_CACHE=lie (the read-back failed, $shape_read)" ;; esac ;;
      esac
      case "$unsound" in *"(the read-back failed, $shape_read)"*) ;; *) why="$why, the read-back boot got no page (status ${shape_read:-none})" ;; esac
    elif [ "$status" = "${SHAPE_TOLD[$sh]}" ] && ! kept "$name" "${SHAPE_MARK[$sh]}"; then
      local lost=""
      case " $knobs" in *" VOLUME_CACHE=lie"*) ! lie_lost volume "$name" || lost="VOLUME_CACHE=lie (the write lost)" ;; esac
      case "$fired" in *" VOLUME_SYNC_FAIL "*) lost="$lost${lost:+, }VOLUME_SYNC_FAIL (the write lost)" ;; esac
      if [ -n "$lost" ]; then unsound="$unsound${unsound:+, }$lost"
      else why="$why, told ${SHAPE_TOLD[$sh]} and the write is not on the volume"; fi
    fi
  fi
  if [ -n "$DURABLE" ]; then
    local read_status
    read_status=$(cat "$WORK/$name.readstatus")
    # Not 200: as a durable shape's (QUEUE 127(c), (f)).
    if [ "$read_status" != "200" ] && [ "$status" != "$TOLD" ] && [ "$read_status" = "$(cat "$WORK/pristine.readstatus")" ]; then
      :
    elif [ "$read_status" != "200" ]; then
      case "$read_status" in
        5??) case " $knobs" in *" VOLUME_CACHE=lie"*) lie_lost volume "$name" && excuse="$excuse${excuse:+, }VOLUME_CACHE=lie (the read-back failed, $read_status)" ;; esac ;;
      esac
      case "$excuse" in *"(the read-back failed, $read_status)"*) ;; *) why="$why, the read-back boot got no page (status ${read_status:-none})" ;; esac
    elif [ "$status" = "$TOLD" ] && ! kept "$name"; then
      # A lie excuses a lost write only when the power took what the cache
      # held; a SYNCHRONIZE failure, only when one failed.
      case " $knobs" in *" VOLUME_CACHE=lie"*) ! lie_lost volume "$name" || excuse="VOLUME_CACHE=lie" ;; esac
      case "$fired" in *" VOLUME_SYNC_FAIL "*) excuse="$excuse${excuse:+, }VOLUME_SYNC_FAIL" ;; esac
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
  # what that one wrote: once one differs, the later ones may differ in any
  # way. Not in turn, or before any differs, each is judged alone.
  local k ks us cex differed=""
  for ((k = 1; k <= $(clients_of "$sh"); k++)); do
    if [ "$k" = 1 ]; then ks="$status"; us=$(status_of "$u"); else ks=$(client_status "$name" "$k"); us=$(client_status "$u" "$k"); fi
    [ "$ks" != "$us" ] || ! cmp -s "$(client_page "$name" "$k")" "$(client_page "$u" "$k")" || continue
    if [ -n "$differed" ] && in_turn_of "$sh"; then cex="client $differed's answer differed first"
    else cex=$(answer_excuse "$name" "$k" "$ks" "$us" "$(client_page "$name" "$k")" "$(client_page "$u" "$k")" "$fired"); fi
    [ -n "$differed" ] || differed="$k"
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
  [ -n "${VOLUME_SITE:-}" ] || { echo "a setup needs VOLUME_SITE=<image>"; exit 1; }
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
  run "$u" $(shape_env "$n")
  # **A KERNEL THAT REPORTS NO PROPERTY JUDGES NOTHING** (2026-10-09): one
  # built without -Dcoverage records its properties and never says them, so
  # "no property broken" would hold of every run, vacuously, all night.
  # Stopped here, before any seed.
  if ! grep -qE '^metal-vmm: coverage: [0-9]+ of [1-9][0-9]* properties' "$WORK/$u.err"; then
    echo "$KERNEL reported no coverage property in its unhurt run: it was built without -Dcoverage, or the run ended before it said any. Nothing can be judged."
    echo "  build one: (cd ~/showell_repos/gopher-metal && zig build gopher -Dcoverage), and copy probe/gopher.elf aside: gates.sh wants the release build there"
    exit 2
  fi
  # **EVERY CLIENT'S UNHURT PAGE** (QUEUE 126): each client past the first
  # is held to its own, so each must have one.
  for ((k = 2; k <= $(clients_of "$n"); k++)); do
    if [ -z "$(client_status "$u" "$k")" ] || [ ! -f "$(client_page "$u" "$k")" ]; then
      echo "${n:+shape $n: }the unhurt run's client $k got $([ -n "$(client_status "$u" "$k")" ] && echo "status $(client_status "$u" "$k") and no page" || echo "no answer"): nothing can be judged; see $WORK/$u.out"
      exit 2
    fi
  done
  if [ -n "$n" ]; then
    st=$(status_of "$u")
    sts=$(statuses_of "$u" "$n")
    echo "shape $n: unhurt status ${sts:-none}, $([ -f "$WORK/$u.body" ] && wc -c < "$WORK/$u.body" || echo no) bytes (${SHAPE_ENV[$n]})"
    if [ -n "${SHAPE_EXPECT[$n]:-}" ] && [ "$sts" != "${SHAPE_EXPECT[$n]}" ]; then
      echo "shape $n: its unhurt run answered ${sts:-nothing}, not ${SHAPE_EXPECT[$n]}: nothing can be judged; see $WORK/$u.out"
      exit 2
    fi
    [ -f "$WORK/unhurt.exit" ] || for x in exit out err body cov; do [ ! -f "$WORK/$u.$x" ] || cp "$WORK/$u.$x" "$WORK/unhurt.$x"; done
    # **A DURABLE SHAPE'S RECIPE MUST HOLD** (QUEUE 125): the pristine
    # volume without its MARK, and its unhurt run told TOLD and keeping it.
    if [ -n "$(read_of "$n")" ]; then
      read_back "pristine-$n" "$VOLUME_SITE" "${SHAPE_READ[$n]}"
      read_back "$u" "" "${SHAPE_READ[$n]}"
      ! kept "pristine-$n" "${SHAPE_MARK[$n]}" || { echo "shape $n: the pristine volume's read-back already holds \"${SHAPE_MARK[$n]}\": nothing can be judged"; exit 2; }
      if [ "$st" != "${SHAPE_TOLD[$n]}" ] || ! kept "$u" "${SHAPE_MARK[$n]}"; then
        echo "shape $n: its unhurt run was told ${st:-nothing} and its read-back $(kept "$u" "${SHAPE_MARK[$n]}" && echo holds || echo lacks) \"${SHAPE_MARK[$n]}\" (TOLD=${SHAPE_TOLD[$n]}): nothing can be judged"
        exit 2
      fi
      echo "shape $n: each seed is read back with $(basename "${SHAPE_READ[$n]}") for \"${SHAPE_MARK[$n]}\" when told ${SHAPE_TOLD[$n]}"
    fi
  fi
done
unhurt_status=$(status_of unhurt)
if [ -n "$DURABLE" ]; then
  read_back pristine "$VOLUME_SITE"
  read_back unhurt
  ! kept pristine || { echo "the pristine volume already holds MARK: nothing can be judged"; exit 2; }
  if [ "$unhurt_status" != "$TOLD" ] || ! kept unhurt; then
    echo "the unhurt post was told ${unhurt_status:-nothing} and its read-back $(kept unhurt && echo holds || echo lacks) MARK: nothing can be judged"
    exit 2
  fi
  echo "durability: each seed posts $POST, then reads back $READ_BACK for \"$MARK\""
fi
if [ -z "$unhurt_status" ] || [ ! -f "$WORK/unhurt.body" ]; then
  echo "the unhurt run got $([ -n "$unhurt_status" ] && echo "status $unhurt_status and no page" || echo "no answer") (exit $(cat "$WORK/unhurt.exit")): nothing can be judged; see its log:"
  tail -5 "$WORK/unhurt.out" "$WORK/unhurt.err"
  exit 2
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
  ( run "seed$seed" FAULT_SEED="$seed" $(shape_env "$sh"); [ -z "$DURABLE" ] || read_back "seed$seed"
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

for name in $(for n in "${SHAPE_NAMES[@]}"; do unhurt_of "$n"; done) $(seq -f "seed%g" "$FIRST" "$LAST"); do
  [ ! -f "$WORK/$name.cov" ] || cat "$WORK/$name.cov" >> "$COVERAGE"
done

echo
echo "coverage over the sweep:"
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
    echo "    repeat it: $(knobs_of "seed$s")${PEER_REQUEST:+ PEER_REQUEST=$PEER_REQUEST}${sh:+ $(shape_env "$sh")} TRANSPORT=$TRANSPORT $VMM $KERNEL <volume${SHAPES:+, after the setup}> \"\" $PATH_WANTED$([ -z "$(read_of "$sh")" ] || echo "; then read back ${SHAPE_READ[$sh]} for \"${SHAPE_MARK[$sh]}\"")"
  fi
done
[ -z "$failing" ] && [ $merged = 0 ]
