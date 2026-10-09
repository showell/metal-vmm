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

**EVERY CLIENT IS JUDGED** (metal-vmm QUEUE 126): a shape of n clients
names n statuses in its `EXPECT`, and each client is held to the same client
unhurt.
- `two-clients`: a player made (`303`) while another's puzzle move is
  written (`204`), at once.
- `session-then-move`: client 1 makes session 2 (`200`), and client 2 moves
  in it (`204`, `game-action-2.http`), asking only once client 1 was
  answered (`PEER_IN_TURN=1`). A move in a session that is not there is a
  404, so a request that damages the next one shows. Once client 1's answer
  differs (a fault cost it), client 2 may answer that 404 (`UNMADE=404`),
  and nothing else its own faults do not excuse.

The site's boot disk says `requests = 1`, which is what ends a run, so
sweep.sh boots each of these from a copy raised to the clients' requests
(`tools/site_requests.py`, metal-vmm QUEUE 127(h)): "shape two-clients: the
site raised to 2 requests". The box's first run of `session-then-move`
answered `200,0` on the unraised site.

`read-puzzles.http` is no shape (it has no `.shape`): it is the read-back of
a durable sweep of puzzle moves. After the setup's two requests, on a copy
of the volume they left (`VOLUME_SITE`):

    TOLD=204 POST=requests/shapes/puzzle-action.http \
      READ_BACK=requests/shapes/read-puzzles.http MARK="session_id: 2" \
      VOLUME_SITE=<the setup's volume> KERNEL=<a -Dcoverage gopher.elf> ./sweep.sh 1 300

A move told 204 must be on the volume after the power fails. This found the
reset that turns the write cache back on (gopher-metal 7b2beb3).
