# Security review, 2026-10-29

A cold review of roc-chat (`main` at `60328c8`) and roc-markdown (`main` at `66b99a7`). It was read-only, with one probe in a scratch copy.

**Overall:** no hole in confidentiality or authentication. The serious findings are availability: almost every request does work proportional to a list any open-sign-up user can grow, inside the one global mutex (the turn).

## High

**H1. Many agents make every request take seconds.** Proven.
- **Where:** `Principal.unique` (`app/Principal.roc:266-287`) is O(n²) (`List.contains` in a fold). It runs on every `Store.accounts!` load, which is every credentialed request and every page.
- **Measured:** 32,000 agents gives about 134 s a load, 16,000 about 30 s, and about 4,000 extrapolates to about 2 s. Nothing caps agents per human, and each new agent rewrites the accounts file with an fsync.
- **The cliff:** past 16 MiB (`files.read_most`), every authenticated request answers 500.
- **Fix:** an O(n log n) or hashed `unique`; a cap on agents per human in `Agents.make`; a cap on total accounts.

**H2. One user can end every other user's live stream, all the time.**
- **Where:** `host/sse.zig:36`. `most_ever = 64` is global, and a new stream evicts the oldest. One user holds 64 and reopens whatever gets evicted; each victim's reconnect re-reads its whole transcript in the turn.
- **The amplifier:** markdown allows a same-origin `<img src="/conversations/N/stream">`, so one message can make every viewer's browser open held streams.
- **Fix:** cap streams per principal (and per IP), evicting within the principal's own; allow `<img>`/`<video>` sources only under an uploads prefix, never any `/` path.

**H3. A transcript is unbounded and re-processed whole on every request; past 16 MiB it bricks the conversation.**
- **Where:** `post!` (`app/Conversations.roc:305`) reads and decodes the whole transcript to compute the next id. `read!` and `/chat/<id>` render every message in the turn, and `stream!` reads it all on each connect. There's no rate or size limit.
- **The cliff:** about 512 maximum-size posts pass `read_most`, and then read, post and stream answer 500 for good.
- **Fix:** keep the count or last id in a sidecar; paginate, and read the stream backlog with `read_at!` from an offset; cap post rate and transcript size.

**H4. Conversations, keys and invites are scanned whole, the key list is sorted in O(m²), and all grow without limit.**
- **Where:** `Store.conversations!` reads every conversation file on `GET /conversations` and `/chat`. `POST /conversations` is unbounded and lists the folder each time. `GET /keys` and revoke read every user's key files, and `by_id` is an insertion sort. Invites work the same way.
- **Fix:** per-user index files (`chat/by-principal/<id>`, `auth/keys-by-owner/…`); `List.sort_with`; caps per human.

## Medium

**M1. Anyone, unauthenticated, can append an fsync'd audit line on every request.**
- **Where:** `/login/github` with no state, `/login/name` with no pending cookie, and `/invites/redeem` with junk. Each refusal is audited with an fsync inside the turn.
- **Fix:** don't audit refusals that carry no identity, or rate-limit or coalesce them; rotate the audit log.

**M2. Any user can pull anyone's agent into a conversation and talk to it.** A policy gap.
- **Where:** `ConvAccess.Conv.start` binds any existing id; `start!` checks only that the starter can post.
- **The risk:** a stranger (sign-up is open) sends `with=agent:7` and posts; a key acting as agent 7 with `Everywhere` read reach sees it. That's a prompt-injection channel into Steve's Claudes, some holding admin keys. The same works for adding any human without consent (spam), and agent ids are sequential.
- **Fix:** require that the starter owns each agent or bot named, or an accept step; default agent keys to `only:` reach.

**M3. Streams outlive revocation.**
- **Where:** `Server.serveStream` authorizes once, at subscribe, with no recheck and no lifetime; pings keep it open forever.
- **What leaks:** a stream keeps receiving after its key is revoked or expires, its session expires, its account is retired, or the conversation goes private. The e2e checks revocation only on new requests.
- **Fix:** cap a stream's lifetime (5 to 10 minutes). The browser resumes through `Last-Event-ID` and is re-authorized.

**M4. The only CSRF defense is SameSite=Lax, which trusts every `*.lynrummy.com`.**
- **Where:** no route checks `Origin` or `Sec-Fetch-Site`, and the post route takes any content type (`text/plain` is a CORS simple request).
- **The risk:** any page on a lynrummy.com subdomain with an XSS or user HTML can post as the victim, start conversations, make agents, and revoke keys and invites (sequential ids).
- **Fix:** on every non-GET route, require `Origin` to be the configured origin, or `Sec-Fetch-Site: same-origin`; optionally require form or JSON content types.

**M5. There's no logout and no session revocation.** A session stays valid for 7 days (24 h idle). Admin's retirement has no route.
- **Fix:** `POST /logout` (remove the session file), plus listing and revoking sessions.

## Low

- **L1. Account enumeration.** `with=human:N` answers "no account is human:N", and a success creates a conversation whose id reveals the total. Fix: one generic error.
- **L2. Same-origin GETs with side effects, through markdown images.** `<img src="/login">`, `/login/github` and `/me` are allowed. The same fix as H2: an uploads prefix.
- **L3. No Content-Security-Policy.** Fix: `default-src 'self'; img-src 'self'; script-src 'self'`, with the inline scripts in `Pages.roc` moved to `.js` files.
- **L4. Gzip on SSE.** `encode gzip` in the Caddy block applies to `text/event-stream` and may buffer it. Fix: exclude event streams from `encode`.
- **L5. The deploy uses predictable `/tmp` paths on prod,** then `sudo install`s them, a TOCTOU window for a local user. Fix: `mktemp -d` under `~steve`.
- **L6. The secrets live in the data root** (`data/secrets/`), which the Roc's file functions can reach. No Roc path can name it today. Fix: move the secrets out.
- **L7. Raw request paths in logs.** `call.zig`'s `replyOf` warnings log the raw path (`sayCrash` escapes it), so a request can inject ESC bytes into logs. Fix: escape it as `sayCrash` does.
- **L8. Unbounded connection count.** Each connection is a task with about 32 KiB, and `kept_open_most` limits only keep-alive. Caddy mitigates this.

## Checked and found sound

- **Cookies:** `__Host-`, Secure, HttpOnly, Lax, Path=/; a fresh random session at sign-in (no fixation).
- **OAuth state:** HMAC'd with a purpose line, bound to a nonce cookie, a 10-minute window, its nonce spent once; no open redirect.
- **Lookups:** MACs verified in constant time; sessions, keys and invites found by the SHA-256 of the secret as a filename.
- **Paths:** fixed prefixes plus digits or hex; the host's path rule; `O_NOFOLLOW`; atomic writes.
- **Visibility:** what you can't see is a 404, like a missing conversation; admins get no read access.
- **Headers and bodies:** an allowlist with CR/LF/NUL checks; body caps of 64 KiB in the host and 1 MiB in Caddy.
- **Crashes and logs:** a crash is a 500 with its line hex-escaped; no secrets in logs or audit lines.
- **systemd** confinement is tight.
- **Pages** escape names, ids and titles.
- **Markdown:** hrefs and attributes escaped and double-quoted; `javascript:`, `vbscript:`, `file:` and `data:` checks robust to case, control bytes and whitespace; media rebuilt from an allowlist, with `src` held to `/x`; the `MSG_` slug restricted to `[A-Za-z0-9-]`.
- **The playground** inserts only the renderer's output of the visitor's own input.
