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
#   - it must break no coverage property (metal-vmm's "N broken");
#   - a volume the guest wrote must still be a filesystem (sound.sh): after
#     a power cut, but for what a stop leaves; and a disk that lied about its
#     cache (`*_CACHE=lie`) and then lost its power is excused (Steve,
#     2026-10-09), as the durability judge excuses its lost write;
#   - the page must be the unhurt run's, status and body, unless the seed
#     reset the connection, made the peer vanish, refused a disk request or
#     cut the power, which may rightly cost the page: then it is "differs
#     (allowed: ...)". A cut volume must still be sound: that is FAT's crash
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
# shape's unhurt run must answer or nothing can be judged. Seed s is the
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
# POST=<request file>, READ_BACK=<path> and MARK=<text>, and VOLUME_SITE,
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
# The page is not compared. The unhurt run must be told 303 and keep MARK,
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
export TRANSPORT="${TRANSPORT:-pci}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
if [ -n "${KEEP:-}" ]; then WORK="$KEEP"; mkdir -p "$WORK"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$REPORT" ] || { echo "no $REPORT; set COVERAGE_SDK=<zig-coverage-sdk checkout>"; exit 1; }
[ -f "$KERNEL" ] || { echo "no $KERNEL"; exit 1; }
[ -f "$SITE" ] || { echo "no volume at $SITE; set SITE=<image>"; exit 1; }
DURABLE=""
if [ -n "${POST:-}" ]; then
  [ -f "$POST" ] || { echo "no request at POST=$POST"; exit 1; }
  [ -n "${READ_BACK:-}" ] && [ -n "${MARK:-}" ] || { echo "POST needs READ_BACK=<path> and MARK=<text>"; exit 1; }
  [ -n "${VOLUME_SITE:-}" ] || { echo "POST needs VOLUME_SITE=<image>: the message is kept on the volume"; exit 1; }
  DURABLE=yes
fi
COVERAGE="$WORK/coverage.jsonl"
: > "$COVERAGE"

# The shapes: their names, and each one's settings as VAR=value words, the
# request files made absolute. No SHAPES is one shape, named "", with none.
SHAPE_NAMES=("")
declare -A SHAPE_ENV=() SHAPE_EXPECT=()
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

# read_back <name> [volume]: an unhurt boot on a copy of that run's volume
# (or the one named), asking for READ_BACK; its page in <name>.read, its
# status in <name>.readstatus. The run's own volume stays as the run left it,
# for sound.sh.
read_back() {
  local name="$1" vol="${2:-$WORK/$1.vol}"
  cp "$SITE" "$WORK/$name.readimg"
  cp "$vol" "$WORK/$name.readvol"
  env VOLUME="$WORK/$name.readvol" PEER_BODY="$WORK/$name.read" \
    timeout "$RUN_TIMEOUT" "$VMM" "$KERNEL" "$WORK/$name.readimg" "" "$READ_BACK" > "$WORK/$name.readout" 2> "$WORK/$name.readerr"
  [ -f "$WORK/$name.read" ] || : > "$WORK/$name.read"
  sed -n -E 's/^peer: ([0-9]+)( "|, [0-9]+ bytes$).*/\1/p' "$WORK/$name.readout" | head -1 > "$WORK/$name.readstatus"
  rm -f "$WORK/$name.readimg" "$WORK/$name.readvol"
}
kept() { grep -qF -- "$MARK" "$WORK/$1.read"; }

# The client's own line (`peer: 200 "..."` or `peer: 200, 13668 bytes`), not
# the wire's account of the peer's frames (`peer: 51 frames sent, ...`),
# which a run whose peer loses frames prints first.
# **EACH FACT FROM THE STREAM THAT CARRIES IT.** A run's stdout is the
# guest's console and the client's line (`peer: 200, 13668 bytes`); its
# stderr is what metal-vmm says itself (the knobs a seed drew, the wire's
# account of the peer's frames, how the peer ended, the coverage line). Read
# together, the wire's "peer: 51 frames sent" was once taken for a status.
status_of() { sed -n -E 's/^peer: ([0-9]+)( "|, [0-9]+ bytes$).*/\1/p' "$WORK/$1.out" | head -1; }
knobs_of() { sed -n 's/^metal-vmm: FAULT_SEED=[0-9]* is //p' "$WORK/$1.err" | head -1; }
# The peer's own end, when it let the page go itself (REVIEW-peer.md S1).
peer_end_of() { sed -n 's/^metal-vmm: the first client \(gave up\|vanished\).*/\1/p' "$WORK/$1.err" | head -1; }
broken_of() { sed -n 's/^metal-vmm: coverage: .*, \([0-9]*\) broken).*/\1/p' "$WORK/$1.err" | tail -1; }

# changed <image>: whether its modification time moved since it was copied.
changed() { [ "$(stat -c %y "$1")" != "$(cat "$1.copied")" ]; }

# verdict <name>: "ok", "differs (allowed: ...)", or "FAIL: ..." for one run
# against the unhurt one.
verdict() {
  local name="$1" u="${2:-unhurt}" why="" exit status knobs broken excuse=""
  exit=$(cat "$WORK/$name.exit")
  status=$(status_of "$name")
  knobs=$(knobs_of "$name")
  broken=$(broken_of "$name")
  if [ "$exit" != "$(cat "$WORK/$u.exit")" ]; then
    # **A CLIENT THAT LEFT BEFORE ITS REQUEST WAS WHOLE IS OWED NOTHING**, and
    # a machine told to serve one request waits for it, idle, until metal-vmm
    # ends the run (exit 1, GuestIdle): long.sh's rough peers allow the same.
    # Only then, and only with no answer given; any other exit fails.
    if [ "$exit" = 1 ] && grep -q '^error: GuestIdle$' "$WORK/$name.err" &&
      { [ -z "$status" ] || [ "$status" = 0 ]; } &&
      { case " $knobs" in *" PEER_RESET_AT="* | *" PEER_VANISH_AFTER="*) true ;; *) [ -n "$(peer_end_of "$name")" ] ;; esac; }; then
      excuse="$excuse${excuse:+, }an idle end after the client left"
    else
      why="$why, exit $exit (unhurt: $(cat "$WORK/$u.exit"))"
    fi
  fi
  [ "${broken:-0}" = 0 ] || why="$why, $broken coverage properties broken"
  # metal-vmm's own fault: a frame lost that no knob asked for.
  ! grep -q "^metal-vmm: the wire was full and pushed out .*, which it never sends again" "$WORK/$name.err" || why="$why, the wire pushed out the peer's frames, which it never sends again"
  # A disk whose power was cut mid-write may hold what a stop leaves
  # (sound.sh, `STOP_LEAVES`), and nothing else.
  local disk_cut="" volume_cut=""
  grep -qE "^metal-vmm: the power was cut (in the guest's write [0-9]+:|after the guest's write [0-9]+ \(sector)" "$WORK/$name.err" && disk_cut=1
  grep -qE "^metal-vmm: the power was cut after the guest's write [0-9]+ to the volume" "$WORK/$name.err" && volume_cut=1
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
    if ! STOP_LEAVES="$disk_cut" "$SOUND" "$WORK/$name.img" > "$WORK/$name.sound" 2>&1; then
      case " $knobs" in
        *" DISK_CACHE=lie"*) [ -n "$disk_cut$exit_cut" ] && unsound="$unsound${unsound:+, }DISK_CACHE=lie (the volume left unsound)" || why="$why, the volume is not sound" ;;
        *) why="$why, the volume is not sound" ;;
      esac
    fi
  fi
  if [ -n "${VOLUME_SITE:-}" ] && changed "$WORK/$name.vol" && ! cmp -s "$WORK/$name.vol" "$VOLUME_SITE"; then
    if ! STOP_LEAVES="$volume_cut" "$SOUND" "$WORK/$name.vol" > "$WORK/$name.vsound" 2>&1; then
      case " $knobs" in
        *" VOLUME_CACHE=lie"*) [ -n "$volume_cut$exit_cut" ] && unsound="$unsound${unsound:+, }VOLUME_CACHE=lie (the attached volume left unsound)" || why="$why, the attached volume is not sound" ;;
        *) why="$why, the attached volume is not sound" ;;
      esac
    fi
  fi
  if [ -n "$DURABLE" ]; then
    local read_status
    read_status=$(cat "$WORK/$name.readstatus")
    if [ "$read_status" != "200" ]; then
      why="$why, the read-back boot got no page (status ${read_status:-none})"
    elif [ "$status" = 303 ] && ! kept "$name"; then
      case " $knobs" in *" VOLUME_CACHE=lie"*) excuse="VOLUME_CACHE=lie" ;; esac
      case " $knobs" in *" VOLUME_SYNC_FAIL="*) excuse="$excuse${excuse:+, }VOLUME_SYNC_FAIL" ;; esac
      [ -n "$excuse" ] || why="$why, told 303 and the message is not on the volume"
    fi
    if [ -n "$why" ]; then echo "FAIL: ${why#, }"
    elif [ -n "$excuse" ]; then echo "lost (allowed: $excuse${unsound:+, $unsound})"
    elif [ -n "$unsound" ]; then echo "allowed: unsound ($unsound)"
    elif [ "$status" = 303 ]; then echo "ok, kept"
    elif kept "$name"; then echo "ok, not told, kept"
    else echo "ok, not told, not kept"; fi
    return
  fi
  if [ "$status" != "$(status_of "$u")" ] || ! cmp -s "$WORK/$name.body" "$WORK/$u.body"; then
    # **A FAULT EXCUSES LESS OF THE PAGE, NEVER ANOTHER ONE** (Steve,
    # 2026-10-08): no answer at all, or the unhurt run's status with its
    # page cut short. Another status (a 404, a 200 where it was a 303) or
    # another page under the same status is a failure, whatever was turned;
    # the one other status excused is a 5xx after a disk fault, below.
    local less=no
    if [ -z "$status" ] || [ "$status" = 0 ]; then less=yes
    elif [ "$status" = "$(status_of "$u")" ] && [ -f "$WORK/$name.body" ] && [ -f "$WORK/$u.body" ]; then
      local got want
      got=$(wc -c < "$WORK/$name.body")
      want=$(wc -c < "$WORK/$u.body")
      [ "$got" -lt "$want" ] && cmp -s -n "$got" "$WORK/$name.body" "$WORK/$u.body" && less=yes
    fi
    # **A SERVER THAT SAYS IT FAILED, WHEN ITS DISK DID**: a 5xx is excused
    # by a fault on the disk or the volume, and by nothing else.
    case "$status" in 5??)
      for k in DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT DISK_BAD_SECTOR VOLUME_CUT_AFTER VOLUME_SHORT_AT VOLUME_GONE_AT VOLUME_READ_ONLY_AT; do
        case " $knobs" in *" $k="*) excuse="$excuse${excuse:+, }$k (a $status)" ;; esac
      done ;;
    esac
    if [ $less = yes ]; then
      for k in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE DISK_CUT_AFTER DISK_TEAR DISK_ROT VOLUME_CUT_AFTER; do
        case " $knobs" in *" $k="*) excuse="$excuse${excuse:+, }$k" ;; esac
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
      # served. Only when another client was answered and the guest served
      # exactly its limit.
      local limit served
      limit=$(sed -n -E 's/^  serving ([0-9]+) request\(s\).*/\1/p' "$WORK/$name.out" | head -1)
      served=$(sed -n -E 's/^  served ([0-9]+) request\(s\).*/\1/p' "$WORK/$name.out" | tail -1)
      if [ -n "$limit" ] && [ "$limit" = "$served" ] && grep -qE '^peer [2-9]: [0-9]+, [1-9][0-9]* of [0-9]+ answers' "$WORK/$name.out"; then
        excuse="$excuse${excuse:+, }the request limit went to another client"
      fi
    fi
    [ -n "$excuse" ] || why="$why, not the page (status ${status:-none})"
  fi
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
  if [ -n "$n" ]; then
    st=$(status_of "$u")
    echo "shape $n: unhurt status ${st:-none}, $([ -f "$WORK/$u.body" ] && wc -c < "$WORK/$u.body" || echo no) bytes (${SHAPE_ENV[$n]})"
    if [ -n "${SHAPE_EXPECT[$n]:-}" ] && [ "$st" != "${SHAPE_EXPECT[$n]}" ]; then
      echo "shape $n: its unhurt run answered ${st:-nothing}, not ${SHAPE_EXPECT[$n]}: nothing can be judged; see $WORK/$u.out"
      exit 2
    fi
    [ -f "$WORK/unhurt.exit" ] || for x in exit out err body cov; do [ ! -f "$WORK/$u.$x" ] || cp "$WORK/$u.$x" "$WORK/unhurt.$x"; done
  fi
done
unhurt_status=$(status_of unhurt)
if [ -n "$DURABLE" ]; then
  read_back pristine "$VOLUME_SITE"
  read_back unhurt
  ! kept pristine || { echo "the pristine volume already holds MARK: nothing can be judged"; exit 2; }
  if [ "$unhurt_status" != 303 ] || ! kept unhurt; then
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
  ( run "seed$seed" FAULT_SEED="$seed" $(shape_env "$(shape_of "$seed")"); [ -z "$DURABLE" ] || read_back "seed$seed" ) &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  seed=$((seed + 1))
done
wait

ok=0
allowed=0
seed="$FIRST"
while [ "$seed" -le "$LAST" ]; do
  v=$(verdict "seed$seed" "$(unhurt_of "$(shape_of "$seed")")")
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
  echo "  FAULT_SEED=$s: $(verdict "seed$s" "$(unhurt_of "$(shape_of "$s")")")"
  if [ -n "$DURABLE" ]; then
    echo "    repeat it: $(knobs_of "seed$s") PEER_REQUEST=$POST VOLUME=<a copy of $VOLUME_SITE> VOLUME_CUT_AT_EXIT=1 TRANSPORT=$TRANSPORT $VMM $KERNEL <disk> \"\" /; then read back $READ_BACK"
  else
    sh=$(shape_of "$s")
    echo "    repeat it: $(knobs_of "seed$s")${PEER_REQUEST:+ PEER_REQUEST=$PEER_REQUEST}${sh:+ $(shape_env "$sh")} TRANSPORT=$TRANSPORT $VMM $KERNEL <volume${SHAPES:+, after the setup}> \"\" $PATH_WANTED"
  fi
done
[ -z "$failing" ] && [ $merged = 0 ]
