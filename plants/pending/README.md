# Plants not yet in the standing set

**disk-write-swallowed** takes a volume write the disk refused as written.
No seed refuses a volume write yet (`knobs.zig` `withVolume` draws none of
`VOLUME_GONE_AT`, `VOLUME_READ_ONLY_AT`, `VOLUME_SHORT_AT`: QUEUE 135), and
the page judge cannot see a hole the server answered 303 over; only a write
shape's read-back can (QUEUE 125). It moves up into `plants/` when both are
in, and `plants.sh` must then catch it.
