# Plants not yet in the standing set

**counted-leak-short** (CC, 2026-10-10, QUEUE 148(d)): the plant the judge's
`counted_leak` excuse must not excuse. A give-back that fails
(`notGivenBack`, where the first full plants run's counted leaks came from:
a write failed and giving its clusters back failed too) counts one cluster
fewer than it leaves, so fsck.fat reclaims one more than the kernel's end
line says. Caught when `counted_leak` refuses (more found than counted) on
a seed that fires it; firing it never and catching it never are both
failures. Applies at gopher-metal master and at CC's branch. Not run (no
guest here). Recipe: `git mv plants/pending/counted-leak-short.patch
plants/ && PLANTS=counted-leak-short ./plants.sh`; the measure is that it
fires in some seed and none of those passes.

Before it: **disk-write-swallowed** moved up into `plants/` (metal-vmm QUEUE
135) once both things it needed were in: seeds that refuse a volume write
(`knobs.zig` `withVolume` draws `VOLUME_GONE_AT`, `VOLUME_READ_ONLY_AT` or
`VOLUME_SHORT_AT` in one seed in eight with a volume), and the write shapes'
read-backs (QUEUE 125), which see a hole the server answered 303 or 204 over.
