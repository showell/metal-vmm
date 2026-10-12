#!/bin/bash
S=$(dirname $(readlink -f $0))
for w in gm181 gm179 gm178; do
  cd $S/$w
  zig build exp181 -Dgopher-root=$HOME/showell_repos/angry-gopher > $S/build_$w.txt 2>&1
  timeout 1500 ./zig-out/bin/exp181 > $S/out_$w.txt 2>&1
  echo "rc=$?" >> $S/out_$w.txt
done
echo done > $S/ALLDONE
