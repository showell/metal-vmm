# Plants not yet in the standing set

**The plants now live in gopher-metal's source** (metal-vmm B39,
2026-10-10): each is a deliberate bug at its site behind
`if (comptime plant.on == .<name>)`, named in gopher-metal's `build.zig`
(`Plant`) and documented in its `src/plant.zig`. `plants.sh` builds one
kernel per name with `-Dplant=<name>`; there are no patches here any more.

A plant the judge cannot see yet stays out of the `Plant` enum until it
can; none is waiting now. `disk_write_swallowed` and `net_goback_byte`
stand.
