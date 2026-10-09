# Whole-machine snapshot and restore: the plan

*Drafted 2026-10-08 by a cold planning agent, reviewed by the box. **Parked
2026-10-09** (Steve): the judge and the class hunts come first. Not built. `src/snapshot.zig` already holds the device half (each model a value
copy restored in place, proven per model); this is the rest.*

## Why

A boot is about 86% of a run's exits (gopher.elf: ~5,500 of ~6,400 come
before the request). Booting once to a point, saving the machine, and
restoring it for each run of a sweep would cut a lossy-sweep run from ~0.22 s
to ~0.05 s. And it is the foundation of convergence: an explorer keeps
snapshots at a few points and branches each run from the latest one before
the fault decision it changes.

**The bar:** a restored run is byte-identical to a fresh run from the same
point (its stdout, stderr, page, both images, coverage lines), and `same.sh`
and `check.sh` stay green.

## The state

**The vCPU** (new ioctls in `kvm.zig`, each with a size assert):

| what | ioctl | note |
|---|---|---|
| general registers | `GET/SET_REGS` | exist |
| special registers | `GET/SET_SREGS2` (0xCC/0xCD, 320 B) | gated on `KVM_CAP_SREGS2`; fall back to `SREGS` |
| FPU and extended state | `GET_XSAVE2` (0xCF) / `SET_XSAVE` (0xA5) | a superset of `GET_FPU` |
| XCRs | `GET/SET_XCRS` (0xA6/0xA7) | |
| MSRs | `GET/SET_MSRS` (0x88/0x89) | list from `KVM_GET_MSR_INDEX_LIST`, each probed; **never** TSC (0x10), TSC_ADJUST (0x3B), 0xE7/0xE8, 0x6E0, APIC_BASE (in sregs) |
| pending events | `GET/SET_VCPU_EVENTS` (0x9F/0xA0) | the only carrier of a vector queued by `KVM_INTERRUPT` and not yet taken; restore after sregs, with the flags GET gave |
| debug registers | `GET/SET_DEBUGREGS` (0xA1/0xA2) | |
| run state | `GET/SET_MP_STATE` (0x98/0x99) | always RUNNABLE here (no in-kernel irqchip): assert it |
| the run page | `run.request_interrupt_window` | set by `rest()` |

**Guest RAM:** copied whole at a save into a huge-page buffer, and restored
by `@memcpy` into the existing mapping, never remapped (huge pages and the
memslot stay). No dirty log yet: it doesn't see the devices' own writes into
guest memory, and it splits huge pages.

**The devices:** `main`'s device locals move into one static `Box`
(`src/box.zig`, to be written); a snapshot is `saved = box.*`, a restore `box.* = saved`
in the same storage, so every pointer between models stays right (assert the
storage is the one saved from). What a value copy misses:
- `cache.Cache.durable` is a heap map: save a clone, and on restore keep the
  live header, clear it, refill from the clone;
- the volume's bytes: generalize `snapshot.Disk` to any `(image, dirty)`;
- write-back to the image files happens once, after the last run of a
  process (the images are private mappings until then).

**Host outputs:** a restored run must print the prefix and then its own
suffix, so its process output is a fresh run's. stdout, stderr and the
coverage fd are captured into memfds from the start; the snapshot carries
the prefix. The coverage run line (which names the knobs) is written when a
run ends, so a branch's line names the branch's knobs.

## The traps

- **A half-finished exit.** For an OUT, IN or MMIO exit, KVM completes the
  instruction on the *next* `KVM_RUN`, and the GET ioctls don't show it.
  Before every save **and every restore**: `quiesce` (set `immediate_exit`,
  run, expect EINTR, clear it; not an exit, not a tick).
- **Where the save happens:** at the top of `serve`'s loop, where nothing
  else is held between exits. The client's connect, now made inside an exit
  (`consider`), moves to the top of the loop after the snapshot hook; prove
  that move changes nothing (`same.sh`, `check.sh`) before anything else.
- **A branch must change nothing before its point:** every named fault's
  first candidate is past what that schedule has seen, a disk cut is past
  the writes so far, no rates (a rate draws dice from the start), no set-up
  knobs (`VOLUME_*`, `DISK_CACHE`, `RTC_*`, `PIT_FROZEN`, `DHCP_LEASE_S`,
  `TRANSPORT`). Anything else is refused by name, never run.
- A snapshot lives in one process (its fds, its memfds); it is not a file.

## The steps

1. **`SNAPSHOT_TWICE=1` with `SNAPSHOT_AT="listening on port 80"`** (or
   `SNAPSHOT_AT_EXIT=n`): save at the point, run to the end, restore, run
   again, compare the two byte for byte and say so; the process's output must
   diff clean against a plain run.
2. **`SNAPSHOT_BRANCH="WIRE_EAT=40"`:** after the restore apply a knob (if
   it may branch), and the result must match a fresh boot with it.
3. **One process, a whole sweep:** boot once, then for each run restore,
   apply, serve, finish, keeping each run's outputs apart; `sweep.sh` and
   long.sh (gopher-metal's release check) use it, and fall back to a boot for a seed that cannot branch.
4. **Several snapshots** sorted by point; a branch restores the latest one
   before its first changed decision (later: snapshots stored as the pages
   that differ from their parent).

New knobs go in `checked.zig` and KNOBS.md.

## Tests

Unit: the vCPU round trip on a fake kernel, the cache's map refill, the
volume's bytes, the branch refusals. Integration: `SNAPSHOT_TWICE` at about
ten points of the probes (during disk writes, around halts, with an
interrupt window pending) each diffed against a plain run; `check.sh` under
it; branches of `WIRE_EAT`, `PEER_EAT` and `DISK_REFUSE` at "listening"
against fresh faulted boots. Every existing script stays green.

**Effort (the planner's estimate):** about 6-7 days for steps 1-2, about 3
more for step 3.
