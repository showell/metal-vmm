# Request shapes for `sweep.sh` and `nightly.sh` (`SHAPES=requests/shapes`)

Each `*.shape` is one kind of request, and seed s sends shape (s mod n).
`setup` runs first, unhurt, on the volume every run starts from: it makes
player p2 and that player's game session 1.

The cookie in the `.http` files that carry one (`gopher_uid=p2.…`) is the
one the setup's `POST /play` is answered with. It holds only while the kernel
and the site volume answer that request with that cookie, since runs are
deterministic. If either changes it, those shapes' unhurt runs answer 303,
not their `EXPECT`, and the sweep stops saying so. To renew the cookie, take
the `set-cookie` from a `POST /play` run with `PEER_RESPONSE=<file>`.

**A WRITE SHAPE IS ALSO JUDGED ON WHAT IT KEPT** (metal-vmm QUEUE 125):
`puzzle-action`, `new-session` and `game-action` carry `READ_BACK`, `MARK`
(and `TOLD`, their `EXPECT` unless said). Each of their seeds is read back by
an unhurt boot on the volume it left, and one told its status whose
read-back lacks the mark fails. Before any seed, a recipe must hold: the
pristine volume's read-back lacks the mark, and the shape's unhurt run keeps
it; else the sweep stops (exit 2), naming the shape.
- `puzzle-action`: `read-puzzles.http` for `session_id: 2`, as below.
- `new-session`: `read-game-2.http` (`GET /game/sessions/2/actions`) for
  `state`, the body its meta keeps (the setup made session 1).
- `game-action`: `read-game-1.http` (`GET /game/sessions/1/actions`) for
  `move-kept`, the move it sends (its body was "y", too short a mark).
- `play` and `register` have none: reading back a player or an account needs
  the cookie the run itself is answered with (its time is the run's), or an
  admin's.

The last two recipes are derived from angry-gopher's game.zig and have not
been run on a guest: `SHAPES=requests/shapes ./sweep.sh 1 10` says at once
whether each holds.

`read-puzzles.http` is no shape (it has no `.shape`): it is the read-back of
a durable sweep of puzzle moves. After the setup's two requests, on a copy
of the volume they left (`VOLUME_SITE`):

    TOLD=204 POST=requests/shapes/puzzle-action.http \
      READ_BACK=requests/shapes/read-puzzles.http MARK="session_id: 2" \
      VOLUME_SITE=<the setup's volume> KERNEL=<a -Dcoverage gopher.elf> ./sweep.sh 1 300

A move told 204 must be on the volume after the power fails. This found the
reset that turns the write cache back on (gopher-metal 7b2beb3).
