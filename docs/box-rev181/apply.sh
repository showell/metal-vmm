#!/bin/bash
# apply the experiment to the worktree at $1
set -e
W=$1; S=$(dirname $0)
cp $S/rev181_exp.zig $W/src/
grep -q rev181_exp $W/src/disk_fat_test.zig || sed -i 's|    _ = @import("disk_fat_test_paths.zig");|&\n    _ = @import("rev181_exp.zig");|' $W/src/disk_fat_test.zig
grep -q exp181 $W/build.zig || sed -i '/if (wanted(test_file, "src\/disk_fat_test.zig")) test_step.dependOn/r '$S/exp_build.txt $W/build.zig
