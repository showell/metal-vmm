# Readability review, 2026-10-29

A cold review of roc-chat (`main` at `60328c8`) and roc-markdown (`main` at
`66b99a7`). Line numbers are as of those commits; later commits move them,
so search for the quoted text.

**Steve's decisions on the open questions:**
- Remove the four unused hosted functions: `read_at!`, `write_cache!`,
  `read_stat!` and `remove!`.
- One HTML escape: roc-markdown's, made to escape `'` as well. roc-chat's
  `Pages.escape` uses it.
- Keep both copies of `Ascii`, each with a header line saying so.

## 1. Comments that are wrong or stale against the code beside them

1. roc-chat `app/Agents.roc:2` and `:13`: the header says a human "mints a key acting as themselves or as one of their agents", and documents `as=agent:7`. The header at `:32` says "a mint acting as an agent or a bot is refused", and `minted!` answers 403 for exactly that. Remove `as=` from the POST /keys line, and drop "or as one of their agents".
2. roc-chat `app/Agents.roc:280`, `mint!`'s doc: "for the session's human or one of their agents or bots (ApiKey decides)". Change it to: "for the session's human; an agent's key comes from an invite".
3. roc-chat `host/e2e.zig:24`: the header says "13. Steve mints a key for it (and C cannot mint one acting as it)", but the table at `:860` says "Steve gets it a key, by an invite (and C cannot invite for it)", and its function is still `mintForAgent` (`:637`). The header's 35-step list copies the `.name` table at `:848-882`, and the two have drifted. Delete the header's list and point at the table instead; rename the function `inviteForAgent`.
4. roc-chat `README.md:189` says "nine planted faults"; `tools/verify.shale:19` says seventeen. Write "the planted faults (verify.shale's header lists them)", with no number.
5. roc-chat `app/Stored.roc:5`: its example line, `account v1 kind=human github=583231 login=octocat role=admin name=Steve H.`, has no `generation=`, which AccountCodec requires (`AccountCodec.roc:328`). The codec list at `:26` (Account, Session, Key, Audit) leaves out ConvCodec, MessageCodec and InviteCodec, and "THE AUTH STORE'S LINE FORMAT" is the format of the chat's records too. Copy AccountCodec's example line, and say "every record the app stores".
6. roc-chat `app/ConvAccess.roc:23-24` says "the code is the first 285" lines; the code runs to `:312`. Say "the code ends at `# ── the cast`" instead.
7. roc-chat `platform/Host.roc:27` names "the two caches' functions, `read_at!` and `write_cache!`", but nothing calls `read_at!`, `write_cache!`, `read_stat!` or `remove!`; `README.md:235-237` repeats the claim. **Steve: remove the four,** from Host.roc, platform/main.roc's hosted list, host/seam/chat_abi.zig, host/call.zig, and the glue snapshot (`tools/chat_glue.shale` regenerates it). Then update the glue count, and the README.
8. roc-markdown `package/MdInline.roc:14-15`, `MdLinks.roc:13` and `MdEmphasis.roc:27-28` say "the Zig's charges, unit for unit…". The package has diverged from the Zig since 2026-10-29; the frozen work units are the spec now. Remove the clause.
9. roc-markdown `package/MdMedia.roc:8-9` says "the Images feed (Feeds, metal-vmm QUEUE 266) ask it". Feeds is roc-webbox's. Drop it, or name roc-webbox.
10. roc-chat `build.zig:74-77` describes e2e as "two clients signed in…". Say "the end to end (host/e2e.zig lists its steps)".
11. roc-markdown `package/Bytes.roc:4` says "roc-webbox's chat has a Bytes of its own". Name roc-chat, or drop the sentence.

## 2. Ticket numbers, review rounds and history where a reason belongs

These are systemic. Delete them; each reason already stands without them.

- **"round two's seventh"-style parentheticals:** about 30 of them, in test-section comments. For example: `Session.roc:243`, `Admin.roc:837` and `:932`, `GitHubSignIn.roc:1351` and `:1367`, `ConvKey.roc:203`, `Principal.roc:404`, `AccountCodec.roc:627`.
- **QUEUE numbers:**
  - roc-chat: `app/main.roc:39` (`# The pages (QUEUE 315).`), `Pages.roc:1`, `README.md:16`, `e2e.zig:1` and `:59`, `verify.shale:1` and `:28`;
  - roc-markdown: `Md.roc:1-2`, `MdSafety.roc:26` and `:118`, `MdMedia.roc:9`, `judge.zig:58`, `verify.shale:1` and `:21`.
- **Plan steps and decision numbers:**
  - "steps 6 and 7", "step 8", "(D2)" and "(D9)" in roc-chat's `README.md:8`, `:18`, `:88` and `:239`;
  - "Every decision is step 6's" in `Pages.roc:4`;
  - "(decision D1)" in `SignIn.roc:44` and `signin_test.zig:8`;
  - "(decision D5)" in `files.zig:24`.

  State each decision itself.
- **"probe (a)":** `server.zig:5`, `call.zig:27`, and the test names at `server_test.zig:77` and `:166`. The reason ("reading the body reuses the head's buffer") stands without the label.
- **"From roc-webbox src/X at 5a4314b, cut to…":** in `chat_abi.zig:8-11`, `chat_route.zig:3-4`, `roc_abi.zig:9`, `bus.zig:4-6`, `sse.zig:4-5`, `files.zig:31-33`, `app/test/crash.roc:6`, `build.zig:159` and `README.md:185`. That's history: at most one README line, if the sync point matters for merges.
- **roc-markdown's port leftovers:**
  - docstrings that open with the Zig function's name (``## markdown `renderTrusted`:`` at `Md.roc:48`, `` `hostileReason` `` at `:74`, `` `renderBlocksInto` `` at `:118`, about 15 more, plus `MdText.roc:13` and `:57` and `MdSafety.roc:25`);
  - `Md.roc:89`'s "the Zig's".

  Remove each prefix and phrase.
- **Narrative and future tense:**
  - `Admin.roc:22-27` ("Soft bans or un-bans are for later");
  - `Admin.roc:39-42`, which warns about roc-webbox's `chat/Retire.roc`;
  - `Pages.roc:110-112` ("not built");
  - `verify.shale:35-36` ("the counts when the pages joined…"): the reason that matters is "they may only rise";
  - the dated "(Steve, 2026-10-29)" in `InviteCodec.roc:1`, `GitHubSignIn.roc:41` and `Admin.roc:22`.
- **"A BAR IS FOR LIFE"** is written out in two headers, GitHubSignIn's and Admin's. Keep one home, and point to it from the other.

## 3. Modules a newcomer can't orient in

- **roc-chat's README layout** (`README.md:163-193`) leaves out 20 of the 31 app modules:
  - the auth core: Access, AccountCodec, Admin, ApiKey, AuditCodec, Cast, ConvAccess, ConvKey, DisplayName, GitHubLogin, GitHubSignIn, KeyCodec, OAuthState, Principal, Session, SessionCodec and Stored;
  - SignIn, Ascii and Bytes.

  It also omits DEPLOY.md (which nothing links), `tools/deploy.shale`, `tools/backup.shale`, `tools/browser_check.js`, `host/files_bench.zig`, `host/auth/path_rule.zig` and `deploy/`. Add one row for "the auth core (pure)", naming its modules, and link DEPLOY.md.
- **`Admin.roc` (1,003 lines) is reached by no route.** Say so in its header and in the README: decided and audited, not yet served. Admin's header doesn't say why it runs past 1,000 lines, and GitHubSignIn's (1,437 lines) doesn't either.
- **roc-chat's `README.md:5`** says it "will serve chat.lynrummy.com", while `DEPLOY.md:3` says it serves it. Give the README one hedged, present-tense status.

## 4. Names that mislead, and one thing with two names

- **`Pages.roc:36`'s route tag `List`** shadows the builtin type. Rename it `ConversationList` (or `Index`).
- **The use tag `Start`** (`Credentials.roc:39`, `Conversations.roc:137` and `:174`, `Pages.roc:65`) covers starting a conversation *and listing them*, so a key refused while listing is audited as `action=start`. Give listing its own use, or name the tag for what it covers.
- **`Agents.Maker`** (`Agents.roc:115`) is the same thing as `ApiKey.Granter`, and is used as the granter in `minted!`, `invited_by!`, `granter_hash!` and `stored_granter!`. Use `Granter` throughout.
- **`GitHubSignIn.Step` and `applied`** ("ONE STEP OF A SIGN-IN'S PLAN") are also how an agent is made (`Agents.make`). The agent-id counter lives there too (`next_agent_id`, `agent_id_after`, `Settings.next_agent_id`), where a reader won't look. Move the accounts-and-settings steps and counters to a module of their own (say `Accounts`), or at least rename them as accounts changes.
- **`GitHubSignIn.next_generation`** (`:241`) is a second name for `fresh_generation`.
- **The first admin** has several names: config `.bootstrap_admin`, `Host.read_config!(BootstrapAdmin)`, `Settings.first_admin`, and Admin's "bootstrap admin". Pick one.
- **`server.zig:51`'s `keepalive_ms`** is the SSE ping; elsewhere "keep-alive" means HTTP's. Rename it `stream_ping_ms`.
- **`bus.zig`** says "frame" in its docs and `msg` in its code (`Next.msg`, `push(msg)`, `expectMsg`). Use one word.
- **`MdInline.roc`'s `$run_start`** means where the pending text starts, while `$runs`, `Run(U64)` and `run_length` mean emphasis delimiter runs. Rename it `$text_start`.
- **`$rb` / `rb`** in MdInline and MdLinks: rename it `$next_bracket`.
- **`Agents.roc:652`'s `by_id`** sorts keys only. Rename it `keys_by_id`.
- **Two `Asked` types:** `Credentials.Asked` (`Credentials.roc:42`) and `Conversations.Asked` (`Conversations.roc:228`, the same fields plus `conv`).
- **`signed_out`** means a 401 answer in Agents (`:734`) and Conversations (`:387`), but a signed-out viewer in `Credentials.roc:88`.

## 5. Logic duplicated

- **`SignIn.me!`** (`SignIn.roc:97-121`) repeats `cookie_session!` (`:69-87`) step for step. Make `me!` call `cookie_session!`.
- **Form and secret sizes:**
  - `form_most = 4 * 1024` is in `Agents.roc:221`, `Conversations.roc:113` and `SignIn.roc:150`: give it one home in Wire;
  - `secret_bytes = 32` (`Agents.roc:226`) and `nonce_bytes = 32` (`SignIn.roc:146`) are one rule with two homes.
- **In Agents:**
  - the same insertion sort twice, `Agents.invites_by_id` (`:545`) and `by_id` (`:652`);
  - an invite's liveness twice, in `Agents.is_live` (`:537`) and in the guard in `Agents.redeemed` (`:187`). Have `redeemed` ask `is_live`;
  - `make_agent!`, `mint!` and `invite!` (Agents `:238`, `:282`, `:347`) each repeat the same prologue: read the body, then `presented!` with four identical arms. Give them one `granter_form!` helper.
- **In Store:** `next_key_id!`, `next_invite_id!` and `next_conversation_id!` are the same "count the folder, plus one".
- **Conversation ids:** `Pages.route` (`:40-52`) parses an id again, repeating `Conversations.id_of` (`:116`), and the two 404s differ (`Pages.roc:254` vs `Conversations.roc:390`).
- **`Conversations.roc:375-385`** gives Wire's functions second names (`json_string`, `commas`, `json`, `refused`). Call `Wire.*` directly.
- **Across the two repos:**
  - `Ascii` is byte-identical apart from its header. **Steve: keep both**, each header saying so;
  - **two HTML escapes differ:** `Pages.escape` escapes `'`, and `MdText.escape_onto` doesn't. **Steve: one escape, roc-markdown's, escaping `'` too.** For roc-markdown, that means exposing it from the package; it moves HTML, so gold is re-frozen and explained by the box.
- **roc-markdown keeps its corpus counts in two places:** `judge/data/ratchet.txt` and `tools/verify.shale:37-39`.
- **`Md.roc`:** `work_units`, `hostility` and `rendered` each build the same `blocks_onto` seed. Give them one `run(md, {wrap, budget})`.

## 6. Functions too long to hold in mind, each with a real seam

- **`MdInline.render_onto`** (about 216 lines, `MdInline.roc:30-246`): "a piece of HTML, then advance `$i` and `$run_start`" happens six times. Make each byte class's branch a scan returning `Try({html, end}, _)`, with one helper taking the piece and moving both cursors.
- **`Md.blocks_onto`** (about 165 lines, `Md.roc:118-283`): every branch ends with the same three assignments. Have a `block_at(...) -> MdText.Block` dispatcher, its result applied once. The raw-HTML block's end scan (`:240-249`) moves into `raw_html_onto`.

## 7. Unclear or over-long prose

- **`KeyCodec.roc:12-14`:** "The record's types are here, the store's shape of a key, and ApiKey's are these; the line is generic over the resource's id, its spelling a number". Rewrite it.
- **roc-chat `README.md:7-20`:** one status paragraph of about 14 lines. Make it three bullets.
- **roc-chat `README.md:43`:** the redeem row is a paragraph inside a table cell, listing seven refusals that Agents' header already gives. Shorten the cell.

## 8. README and TESTING accuracy (roc-markdown)

- **The README claims more than the corpora hold:**
  - "CommonMark's and GFM's spec examples": `spec_diverge.txt:9` says "considered 401, kept 269", and nothing says how the 269 were chosen. Say "269 of the specs' examples", and say how they were chosen;
  - "thousands of hostile inputs": there are about a thousand (1,032).
- **The exports:** `package/main.roc` exposes `MdFence`, `MdMedia` and `MdTable`, but the README's Use table documents only `Md`, and nothing says why the others are exposed.
- **The examples' two names:** `judge/data/corpora.txt` calls `examples.jsonl` "the REPL's canned examples", while TESTING.md calls them the playground's. Name both.

## 9. Tests: can a reader tell what each proves?

Mostly yes: the Zig test names, ConvAccess's table and Session's liveness table read well. The exceptions:
- **`MdInline.roc:396`,** `expect inline("http://localhost:9100/x.md") == …`, has no comment. It pins "a host without a dot is not autolinked": say so.
- **`Md.roc:660`,** "# markdown.zig's own cases.", is a provenance label. Say what the group proves.
- **`MdEmphasis.roc`,** "the hardest code in the package", has no `expect`s. Add worked examples of the rule of 3 and the floor.
- **`Pages.roc:319`'s `Str.count_utf8_bytes(conversation_js) > 0 and`** is noise in front of the real check.
