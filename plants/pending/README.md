# Plants not yet in the standing set

None now. **disk-write-swallowed** moved up into `plants/` (metal-vmm QUEUE
135) once both things it needed were in: seeds that refuse a volume write
(`knobs.zig` `withVolume` draws `VOLUME_GONE_AT`, `VOLUME_READ_ONLY_AT` or
`VOLUME_SHORT_AT` in one seed in eight with a volume), and the write shapes'
read-backs (QUEUE 125), which see a hole the server answered 303 or 204 over.
