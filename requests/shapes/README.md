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
