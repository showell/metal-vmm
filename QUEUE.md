# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox, shale and dog-park: what is open, and who has it.
**Finished, retired and answered items are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, one line each by number with the
commits they name; their full text is `git show 3697b1c:QUEUE.md` and `git show
3697b1c:QUEUE-ARCHIVE.md`. New items take `queue_next()`'s number. The conversation between
the two Claudes is [`FEEDBACK.md`](FEEDBACK.md) (older entries:
[`FEEDBACK-ARCHIVE.md`](FEEDBACK-ARCHIVE.md)); the cloud session's charter is
[`CLOUD_WORK.md`](CLOUD_WORK.md).

## Context

metal-vmm runs zig-metal-unikernel's real kernel deterministically (both machines:
microvm-shaped and `TRANSPORT=pci`); the scenarios that cover what the site
meets go here, not to QEMU, which stays on the happy path (Steve). The goal
is zero bugs in the lower levels; class hunts find more than seeds; the
judge is becoming "did anything forbidden happen?", checked by `plants.sh`.
The snapshot (`docs/SNAPSHOT.md`) is parked.

## Now

- **What serves lynrummy.com:** zig-metal-unikernel's newest tag
  (`git -C ../zig-metal-unikernel tag -l 'v*' --sort=-v:refname | head -1`);
  its message names the commits. Dog Park serves dogpark.lynrummy.com.
- **Built, not deployed (Steve's):** the Observatory's droplet (228). Dog
  Park's release with `/version` serves (its `/version` names the commit).
- **CC:** Shale's work is the box's (Steve, 2026-10-22), but for 244. The
  box builds with a patched Zig 0.17.0 (FEEDBACK, 2026-10-26).

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**332. chat-client: no back/forward navigation; r quotes like q: CC'S** (Steve, 2026-10-31.) Slim the shared JS client, showell/chat-client, which production's Zig chat serves (angry-gopher's zig-server builds it by path) and roc-chat may reuse. Branch `claude/slim-nav` in chat-client; the box reviews, runs the JS gates, merges, and Steve deploys production.

**Remove the back/forward navigation, all of it:**
- the `b` and `f` keys (chat_help.js's table, and anything else that binds them);
- the Back and Forward buttons in the middle pane's navbar (middle_pane.js), and the navbar itself if nothing else lives there (chat_search.js puts a control "next to back/fwd": keep that control working wherever it lands, and say where);
- js/nav_stack.js and every caller and dependency (`back`, `forward`, `onChange`, the pushes from setSelectedBubble), plus comments and docs that describe it (the README's layout list, message_view.js's notes, docs.js);
- bundles.zig's entry for nav_stack.js if it goes, and CONTRACT.md / contract/contract.json if they mention any of it.
Selection, the URL hash (`#msg-<id>`), and following a message reference must keep working exactly as now; only the history of selections goes.

**Make `r` a synonym for `q`:** quote-reply to the selected message, alongside `q` and `>`. The online help (chat_help.js's key list, which drives the help panel) shows it plainly, e.g. "q, r (or >)", and lists no b or f.

**Gates: run only the JS gates, nothing else.** In chat-client: `zig build test`, `node tools/test_chat_resize.mjs`, `node tools/test_contract.mjs`. In angry-gopher, with your chat-client checkout as its `../chat-client`: `ops/test_chat` (JS syntax, the resize decision, the JS lint). Don't run angry-gopher's or roc-chat's other gates. If the lint flags something your removal leaves (dead code, an allowlist naming a removed function), fix it at its root.

**Talk:** the content goes in FEEDBACK as usual (what went, what stayed and why, the gates' output). When it's pushed, also post a short line in roc-chat conversation 3 that mentions `@LC` (e.g. "@LC slim-nav is pushed; details in FEEDBACK"): that wakes the box, which is listening there.

**331. Agent-to-agent, next: a hop is an agent answering an agent; mentions parsed by the server; a server cap: CC'S** (Steve, 2026-10-30, on the box's plan after the first round trip: "go with your order".) Three parts, in order, one commit each. Shale's listen recipe is merged on master; roc-chat work goes on `claude/roc-chat` from main, after the box's pin move to nightly-2026-10-30-0602c5f lands (pull main first; if it hasn't landed, start with part 1).

**Part (1): rule 3 counts only agent-to-agent replies.** In conversation 3, your status post #8 used up a hop, so LC's real question #9 was dropped. Change the count in cookbook/listen.shale's `for_me`/`consume`: an agent's post is a hop only when it mentions another agent; an agent's post that mentions no agent (a status, an answer to a human) costs nothing; a human's post still resets. Plants: an agent status post followed by an agent question is heard; three agent-to-agent mentions in a row still stop at two hops.

**Part (2): roc-chat parses mentions, so the rule has one home.** Each message's JSON (transcript, stream frame, post answer) carries `"mentions":["agent:2", ...]`: the participants of that conversation the markdown names as a word (`@Name`, or `Name` leading the post), by their display names, decided by one pure function with expects. Only participants count; nothing else in the answer changes. Then listen.shale reads `mentions` when present and its own `mentions` function stays only as the fallback for an older server, or goes: your call, said in FEEDBACK. e2e steps for a mention, a non-mention (`@CCX`, `a@CC.com`), and a name that isn't a participant. The shared JS client must not need a change (it ignores the new field; say how you checked).

**Part (3): a server backstop against runaway agents.** roc-chat refuses an agent's post when the conversation already has N agent-to-agent posts (agent posts mentioning an agent) since the last human post: a 429 with a plain-text reason naming the limit, nothing stored, audited. Pick N (I'd say 4: twice the listeners' two hops, so polite agents never meet it) and put it in Limits.roc with its reason. An e2e step and a plant (the cap never reached) that turns it red.

**Finish:** roc-chat's `tools/verify.shale` once at the end, and cookbook-test for part 1; counts in FEEDBACK. Fast loop as before: quick checks between parts.

**330. listen.shale: an agent hears the posts meant for it: CC'S** (Steve, 2026-10-30, on 328: "yes, mentions plus two hops, build listen.shale first".) Build the recipe 328 proposed, in Shale's cookbook, beside cookbook/zulip.shale. Branch from Shale master; the box merges.

**What it does:** listen.shale holds one roc-chat conversation's stream (`GET /conversations/<id>/stream`, with `Last-Event-ID` to resume) using the agent's key from a secrets mount (`key=keys:<file>`, passed only through `run`'s `secrets`), and prints one line per post that is for the agent: `#<id> by <principal>: <first line, trimmed>`. Arguments: `site=`, `conv=`, `me=` (the agent's principal id, such as `agent:2`), `name=` (the word a mention uses, such as `CC`), `key=`, `after=` (the last id already handled). Never print the key.

**The rules, as 328 proposed:** (1) never a post by `me`; (2) only a post whose markdown mentions `name` as a word (`@CC`, or `CC` leading the post); (3) a post by an agent counts only if a human posted since the last two agent posts: at most two agent hops before a human speaks, counted from the conversation's own posts, not remembered by the listener. Put the decision in one pure function, separate from the stream I/O, so it can be tested alone.

**Modes:**
- default: listen and print until stopped (a cloud session holds it under `Monitor`);
- `once=1`: exit 0 on the first post for the agent, printing just that line. **This is how the box listens:** a detached command that exits wakes the box's session. Also exit nonzero, loudly, when the stream ends or the key is refused, so a dead listener is never mistaken for a quiet conversation.

**Tests:** `self_test=1`, run by `zig build cookbook-test`, with no roc-chat build and no network. Feed recorded SSE frames from plant files (a new cookbook/plants/listen folder, in the format the roc-chat stream sends: read its `id:` / `data:` frames and its `: ping` lines) through the same parsing the live path uses. The plants: a human's "@CC hi" gives one line; CC's own post, a post naming nobody, a third agent hop and a `: ping` each give none; resuming with `after=` prints nothing twice. Plant a fault (e.g. rule 3 disabled) and see a test go red. Use `fresh_dir` for anything written.

**A live check against prod, by hand, once:** in conversation 3, run `once=1` as CC, have LC (the box) or Steve post a mention, and see it exit with the line. Say in FEEDBACK when you're listening, so the box can post the "@CC" at the right time, or post it yourself from a second key-holding run only if that doesn't break rule 1.

**Docs:** a row in cookbook/README (or wherever cookbook/zulip.shale is listed) and in docs/SHALE-AGENTS.md's table of recipes. Present tense, no task numbers.

**Finish:** cookbook-test and the doc check, counts in FEEDBACK.

**329. Shale's cookbook: no fixed scratch paths: CC'S** (Found while fixing tools/doc_check.shale's self-test, whose fixed fixture folder made two concurrent runs collide; it now takes a `mktemp -d` folder of its own.) The same pattern is in the cookbook. Under `zig build cookbook-test` each run gets a fresh scratch, but on a box whose `scratch` mount is shared, two runs at once collide:
- cookbook/branch_prune.shale: `scratch:branch_prune_self_test`
- cookbook/roc/methods.shale: `scratch:methods`
- cookbook/zulip.shale: `scratch:zulip_topic.json`
- tools/coverage.shale: `.zig-cache/coverage/prelude_hits`, removed and rebuilt each run

Give each run a folder of its own, cleaned after (doc_check's `fresh_fixture_dir` is the shape), and prove it as doc_check's fix did: run two at once, several pairs, see one collide before and none after. Leave cookbook/zig/move_judge.shale's and cookbook/zig/same_tests.shale's baseline files alone; they're fixed on purpose. Branch from Shale master; finish with `zig build cookbook-test` and the doc check, the counts in FEEDBACK. The box merges.

**328. Agents that listen: a design proposal, no code: CC'S** (Steve, 2026-10-30, after the first three-way conversation.) Today an agent in roc-chat reads only when told to, so a reply comes when Steve nudges. The next layer is agents that listen: an agent learns that a post is for it and answers, or wakes its session. **Write a design proposal in FEEDBACK; change no code.** Steve steers it after lunch.

**Read first:** roc-chat README (routes, "The model", "For an agent"), its stream route and how the page uses `EventSource`, the essay notes/three-of-us-in-conversation-three.md in showell/essay-repl-server, and Shale's docs/SHALE-AGENTS.md on detached jobs.

**Cover, briefly and concretely:**
- **Who listens, and where it runs.** For the box (a long-lived machine) and for a cloud session (which ends): a Shale recipe that holds a stream; something the roc-chat host runs for an agent; polling; or another shape. What each costs, and what fails when.
- **What wakes an agent** in each place: what exists today to wake a Claude Code session, on the box and in the cloud, and what doesn't. Say plainly what you don't know.
- **What a post "for an agent" means:** every post in a conversation it's in, a mention, or something else; and how to keep two agents from answering each other forever.
- **What roc-chat would need** (routes, a key's scope, limits), and what can be built with what's there now.
- **A smallest first step** that would make conversation 3 feel live, and how we'd test it (an e2e step, a plant).
- **Your recommendation,** with the trade-offs.

Keep it under about two screens. The roc-chat JS client is shared with production's Zig chat and stays verbatim for now, so prefer designs that don't change it.

**327. Get ready for your roc-chat invite, then redeem it: CC'S** (Steve, 2026-10-30.) The goal: Steve, CC and LC in one conversation on chat.lynrummy.com. **Do steps 1 to 6 now, before any invite exists,** so nothing unexpected happens inside the invite's ten minutes. Work as steve, in Shale.

**Step (1): Shale.** Pull showell/shale master and rebuild it. Confirm the new option: `run({"printf","x"}, {timeout_ms=5000, stdout_secret="repos:nope"})` must be refused, naming a `secrets` mount. Refused as an unknown option means a stale build.

**Step (2): your secrets folder,** as Shale's docs/SHALE-AGENTS.md, "Setting up your own secrets folder", says: a folder made with mode 700 at steve's home, .shale-keys, owned by steve, and the mounts line `keys = ~/.shale-keys secrets`.

**Step (3): a rehearsal,** with a harmless value. `run({"printf","rehearsal"}, {timeout_ms=5000, stdout_secret="keys:rehearsal", secret_replace=true})`: `secret_written` true and `secret_bytes` 9. Read it back only through `secrets`: `run({"sh","-c","test \"$R\" = rehearsal"}, {timeout_ms=5000, tail=5, secrets={R="keys:rehearsal"}})` exits 0.

**Step (4): curl** is 8.3 or newer (`--variable` and `--expand-header` need it).

**Step (5): prod, spending nothing.** `curl -s -w '\n%{http_code}' https://chat.lynrummy.com/invites/redeem -d code=00 -d format=bogus` answers 400, "format is `secret`, or left out for the key as JSON".

**Step (6): the redeem, written and not run.** A Shale script taking `code=` that runs `run({"curl","-s","https://chat.lynrummy.com/invites/redeem","-d","code=" .. code,"-d","format=secret"}, {timeout_ms=30000, stdout_secret="keys:roc_chat_cc_key"})`, fails loudly unless `secret_written`, prints only the exit code and `secret_bytes` (65 expected), then lists your conversations with the key: curl `--variable %CC_KEY --expand-header 'Authorization: Bearer {{CC_KEY:trim}}'` with `secrets={CC_KEY="keys:roc_chat_cc_key"}`. Never print the secret.

**Then report in FEEDBACK:** a line per step, pass or fail, and "ready for the code". Also write 326's FEEDBACK entry (the box merged your 326 branch with main's redeem change and is verifying it).

**Step (7), when Steve gives you the code and a conversation number:** run the script from step 6 at once, then read that conversation with your key (roc-chat README, "For an agent") and post a hello. Say in FEEDBACK how it went.

**326. roc-chat onto the style guide: builders, then the hunts: CC'S** (Steve, 2026-10-30: "Let's get roc-chat up to speed with the style guide, of course.") Start from roc-chat main after the box's commit "Method calls: 782 of ..." lands (pull first); work on `claude/roc-chat`.

**Working loop (Steve, 2026-10-30):** roc-chat is unused and unannounced, so move optimistically. Between edits use the shortcuts (roc-apps CLAUDE.md §14): the dev backend, `roc check` on app/main.roc, `roc test`, one targeted plant. Commit each part as it holds. Run `tools/verify.shale` once, at the end; if a part breaks something only verify sees, say so rather than re-running verify after every part.

**Part (1): JSON through one opaque builder.** roc-apps docs/roc-style.md, "Structured output goes through one opaque builder", and its note that roc-chat doesn't follow it yet. Every JSON answer (today about 19 `Wire.json(...)` calls spliced by hand, such as Agents.roc's `key_json`) goes through a `JsonOut`-style opaque type whose `string`, `number`, `bool`, `array`, `object` and `bytes` are the only way out. Expects pin the exact bytes, including a name holding a quote, a backslash and a control character. The e2e answers must not change byte for byte except where today's splice was wrong; name any such case.

**Part (2): pages through an opaque Html.** The same rule for Pages.roc and the page builders: a page is built only from escaped text and literal markup, with no `List.join` of raw strings outside the builder. Keep the markup the pages emit today unless it was wrong. A plant: a page builder given a name with `<script>` still renders it escaped.

**Part (3): run the cookbook hunts over app/ and act on them.** `name_hunt`, `errors`, `boundaries`, `nest_depth`, `stack`, `roc_commas` (Shale's cookbook/roc/README.md says how). Fix each finding, or leave it with a one-line reason in FEEDBACK. A finding is a question for a reader, not a verdict; `boundaries`' `single` is a rule of thumb.

**Part (4): keep it fixed.** Where a hunt reads zero after part 3, add it to `tools/verify.shale` as a check that must stay zero, with a plant that turns it red. Then update roc-style.md's note: roc-chat follows the builder rule now (send the roc-style edit as a proposed diff in FEEDBACK; the box commits roc-apps).

**Finish:** verify passes, its summary in FEEDBACK, with the hunts' counts before and after.

**325. Read roc-apps' CLAUDE.md: an adversarial review, and getting up to speed: CC'S** (Steve, 2026-10-30.) **Read only; no commits outside metal-vmm's FEEDBACK.** Do it in this session, so what you learn stays with you for the next Roc item.

**Read:** showell/roc-apps `CLAUDE.md` in full: fourteen problems working in Roc, each with our answer. It's the authority on how we do Roc now. Read roc-apps' style guide and compiler notes (docs/roc-style.md and docs/roc-notes.md there) as it points to them. After this, follow the CLAUDE.md in every Roc item.

**Review it adversarially.** Set out to find where it's wrong, not to confirm it:
- **A claim that's false:** a path that doesn't exist, a command that doesn't do what it says, a rule the code breaks. Check against roc-chat, roc-markdown, roc-apps and Shale, and run what's cheap (`roc check` on a scratch file, a quick test, a grep).
- **Unclear text:** an agent who knows older Roc but none of our code would misread it.
- **Contradictions,** between sections, or with the style guide, roc-notes or CLOUD_WORK.
- **Missing pieces:** what your own Roc work on 309 to 324 taught you that a newcomer needs and the file lacks. Name the item it came from.
- **What misleads a cloud agent in particular:** the toolchain release, sandbox limits, running as `steve`, the §14 shortcuts.

**Report in FEEDBACK,** one entry. For each finding give the section, the claim quoted briefly, the evidence (a path, a command and its output, or the code that disagrees), and a proposed fix in a sentence or two. Rank the findings, most serious first. Then add three to five lines on what in the file was new to you. Don't edit roc-apps: the box judges each finding, may amend or decline it, and integrates.

**324. roc-chat: agents, invites and keys on the /chat pages: CC'S** (Steve, 2026-10-30: wait "for things like invite buttons to be built before doing any real testing"; the goal is a three-way conversation of Steve, CC and LC on chat.lynrummy.com, set up entirely through the pages.) **showell/roc-chat only**, on `claude/roc-chat` branched from main `b66de68`. **Read FEEDBACK's newest box entry first:** the Roc pin moved to 2026-10-29, installed from roc-apps's `toolchain-2026-10-30`. Finish as 322 did: verify passes, its output goes in FEEDBACK, and the box merges.

**What a human can do from the pages, with no console:**
- **See and make agents:** the viewer's agents (name and id), and a form to make one (`name=`). Their keys show alongside, with a revoke button.
- **Invite an agent:** a button on each agent makes an invite and shows its code once, with the ten minutes it lives and plain words on what to do with it. A copy button helps. Live invites list with a revoke button, never showing a code.
- **Start a conversation with people and agents:** the start form already takes `with=`. Make it easy to pick one's own agents, plus another person's id typed in.
- **Where it lives:** a page of its own (for example `/chat/agents`) linked from `/chat`, or a section of `/chat`. Choose one and say why.

**Rules:**
- The pages call the routes that exist. Add a route only if a page truly needs one, and say why.
- A code or secret appears in exactly one response, the one that made it, and never in a list, a log or the audit.
- Everything a page writes itself is escaped. A key is never given a page (403).
- Posts from the pages pass the Origin check, as they do today.

**The agent's side stays the API:** an agent redeems with `POST /invites/redeem` and then uses its key. Add a short "For an agent" section to the README: redeem with curl, keep the secret in a file, post and read with `Authorization: Bearer`.

**Proof:**
- e2e steps that drive the pages as a browser would: the agents page lists only the viewer's agents; making an agent appears there; an invite shows a code once and the next load shows none; a revoke removes it; another human sees none of it (404 or nothing listed); a key gets a 403. Each step needs a plant that turns it red.
- `tools/browser_check.js`, extended to click through: make an agent, invite it, see the code once.

**Not here:** roc-chat's method-syntax rewrite (`cookbook/roc/methods.shale`). The box runs it after this merges, so don't hand-convert calls beyond the code you touch. The style guide's rule applies to new code.

**323. Shale cookbook: old-style Roc calls rewritten to method syntax: CC'S** (Steve, 2026-10-30.) **showell/shale only**, on a `claude/` branch. Finish with Shale's `zig build test` (which runs every recipe's self-test) and `zig build consumers` passing, their output in FEEDBACK; the box merges.

- **What it does:** it turns `Module.fn(first, rest...)` into `first.fn(rest...)` (static dispatch), but only where that is the same call: where `first`'s type is `Module`'s own type. Examples are `List.map(xs, f)` to `xs.map(f)` and `Str.concat(a, b)` to `a.concat(b)`.
- **How:** follow cookbook/roc/name_hunt.shale for the parse and for roc-ast.
  1. Find each candidate in roc-ast's tree.
  2. Rewrite one file at a time.
  3. Keep a file's rewrite only when `roc check` passes and `roc test`'s expect count and results are unchanged.
  4. Otherwise revert that file and list its candidates as left for a hand fix, each with its reason.

  The syntax tree alone can't prove the type, so the compiler is the judge.
- **Its output:** a count line (candidates, rewritten, left), and for each one left, `file:line` and why. Make the default a dry run that lists what it would change; `apply=1` writes.
- **Don't rewrite:**
  - a call whose first argument's type differs from the module's (`Str.from_utf8(bytes)` takes a list);
  - a call used as a function value (`List.map(xs, Str.trim)`: the outer call converts, the inner `Str.trim` stays as it is);
  - a module's own call to one of its functions, where a method would be ambiguous: judge this, and say what you chose.
- **Chained calls:** `List.len(List.keep_if(xs, p))` becomes `xs.keep_if(p).len()`, from the inside out.
- **Plants:** each must come out as it says, under `self_test=1`:
  - a call that must be rewritten;
  - one that must stay because its first argument's type differs;
  - a chained call;
  - a call passed as a function value;
  - a file whose rewrite breaks `roc check`, which must be reverted and reported.
- **README:** a row in cookbook/roc/README.md.
- **Try it on roc-chat's `app/`** as a dry run only, and put the count line in FEEDBACK. Don't commit to roc-chat.

**322. roc-markdown: the chat says which URLs are its uploads: CC'S** (Steve, 2026-10-30: "The URL is what makes sense from the markdown processor's perspective. The actual file location of the image is the chat's responsibility, not the markdown processor's.") **showell/roc-markdown and showell/roc-chat**, on `claude/roc-markdown` (on top of 318) and `claude/roc-chat`. Finish as 318 does, plus roc-chat's verify; the box merges both and re-freezes gold.

- **The split:**
  - **The package** judges a media URL as a URL: same origin, no `..` in any spelling a browser resolves, no encoded separator, no control bytes. 318 already does all this.
  - **The caller** says which same-origin paths are its uploads, through the render options. A predicate on the path is the likely shape, since the old chat's uploads (`/chat/c/<conv>/<topic>/uploads/…`) are no single prefix. Choose what the pin allows and say why.
  - MdChat keeps no uploads path of its own, and nothing defaults to one: a caller that names no rule renders no media.
- **Who passes what:**
  - roc-chat passes its own uploads URL (`/user_uploads/` unless roc-chat already serves uploads elsewhere; check).
  - The judge passes, per corpus, the rule its cases were written for: the old chat's shape for gold and the Zig-derived corpora, and `/user_uploads/` for the dialect and examples.
  - The playground passes `/user_uploads/`, where its sample image lives.
- **Expected effect:** with the old chat's rule, most of 318's 13 `unit_cases` moves and its gold moves should come back. Every remaining move is named in the commit.
- **README:** one line saying where the uploads rule lives and why.
- **Plants:** a caller's rule ignored (media rendered without asking it); a `..` path passed by a permissive rule.

**321. roc-chat: security H4, per-person indexes and caps: CC'S** (Steve, 2026-10-29: the security review's H4, which nobody has started.) **showell/roc-chat only**, on `claude/roc-chat`, after 320 and on top of it. Finish as 319 does.

- **Per-principal index files** for conversations, keys and invites, so that listing what one person owns no longer scans everyone's. A missing index is rebuilt once from the full scan, the same pattern as H3's tally, so no deploy migration is needed. Give a stale index the tally's treatment too: detect it and rebuild.
- **The caps:** wire `keys_per_human`, `invites_per_human` and `conversations_per_human` from the Limits module. A request past a cap is refused with a status and a message that say which cap.
- **Sorting:** `List.sort_with` replaces Agents' insertion sorts.
- **e2e:** one step per cap, with a test hook for a small cap, and a plant per step that turns it red.
- **Verify:** as 319.

**320. roc-chat: security H3, the rest: CC'S** (Steve, 2026-10-29.) **showell/roc-chat only**, on `claude/roc-chat`, after 319 and on top of it. Finish as 319 does. H3's first part, on `box/security-2`, gave each post its id from a tally sidecar and capped a transcript at 4 MB. Read docs/reviews/REVIEW-roc-security-2026-10-29.md (this repo) for H3 itself.

- **Paging:** `GET /conversations/<id>` returns the last page of messages (`page_messages` in the Limits module), and takes `?before=<id>`. The /chat page shows the last page and can load the one before. List the new contract fields first, and update chat-client's CONTRACT.md if the wire changed (a separate commit there; say so in FEEDBACK).
- **The backlog after `Last-Event-ID`:** `stream!` still reads the whole transcript. Grow the tally an id-to-offset index, or anything that bounds the read, and use `read_at!`. Note that 319 removes the unused hosted functions: keep `read_at!` if this needs it, and say so.
- **Small:** `chat_abi.zig`'s header comment names `stream_holder`.
- **A known trap:** an e2e `Listener` read past its timeout aborts the run (std's Io panics in debug builds) instead of failing the step. Step 40's `ends()` waits on `poll` instead; any new step that waits for data that may never come does the same.
- **Verify:** as 319, with each new step's plant red.

**319. roc-chat: the readability review's fixes: CC'S** (Steve, 2026-10-29.) **showell/roc-chat only**, on `claude/roc-chat`. **Startable now:** branch from roc-chat's `box/security-2` (b2dd182: M3, M1, H2 and H3's first part; its agent's verify passed 77 of 77, and the box hasn't re-run it yet). The box merges that branch and yours together. Finish as 314 did: roc-chat's verify script passes in full, its output goes in FEEDBACK, and the box merges.

**Read first:**
- docs/reviews/REVIEW-roc-readability-2026-10-29.md (this repo): take every **roc-chat** finding. The roc-markdown ones are 318's;
- Steve's decisions at its top:
  - remove the four unused hosted functions;
  - pages use roc-markdown's one HTML escape, which 318 exposes; if 318 isn't merged yet, leave `Pages.escape` and say so;
  - keep both `Ascii` copies, with a header line saying why.

Its line numbers are old (a restyle and renames came since: the Store's lookups are `load_*!`): search for the quoted text.

**Also:**
- **The bypass:** `ConvAccess.Conv.start` (the raw constructor) is still public beside `start_by`, which holds the owner rule (security M2). Make the rule impossible to bypass from app code: test-only construction, or one constructor taking the starter, whichever the pin allows. Say which.
- **`name_hunt`'s 24 remaining `noun_effect` findings:** route handlers are `serve_*!`, and fallible lookups `load_*!`. A Shale fix teaching it mint, redeem, audit, spend and echo may land first; rerun the recipe.
- **The domain refusal aliases `errors` flags** (`GitHubSignIn.Refusal`, `InviteCodec.Refusal`, `ApiKey.Refusal`, and so on): judge each one, keep a shared alias only where it's one vocabulary on purpose, and say why at its definition.

**Verify:** the floors don't fall, every plant stays red at its step, and both formatters are clean. Run as `steve`.

**318. roc-markdown: the reviews' polish, the uploads prefix, one escape: CC'S** (Steve, 2026-10-29: "Keep polishing markdown as top priority"; "2) yes" to the uploads prefix.) **showell/roc-markdown only**, after 317 and on top of it, on `claude/roc-markdown`. Finish as 316 and 317 do: roc-markdown's verify script passes, its output goes in FEEDBACK, and the box merges, re-freezes gold and explains every move.

**Read first:** two cold reviews from today, in this repo:
- docs/reviews/REVIEW-roc-readability-2026-10-29.md: take every roc-markdown finding. The roc-chat ones are the box's.
- docs/reviews/REVIEW-roc-security-2026-10-29.md: take H2 and L2's markdown half.

Their line numbers are as of roc-markdown `66b99a7`; search for the quoted text.

**Do, in this order, each its own commit:**
1. **The uploads prefix** (security H2 and L2; Steve's decision).
   - Today `MdSafety.is_local_url` allows any `/` path for `<img>` and `<video>`, which lets a message aim media at the app's own routes (`/conversations/N/stream`, `/login`).
   - Allow only paths under one uploads prefix. It's the chat's convention, so it lives in MdChat, with `/user_uploads/` as the default. MdSafety asks MdChat for it.
   - The rule applies to rebuilt `<img>`/`<video>` tags and to 317's `![alt](src)` alike.
   - Freeze cases for the inside and outside sides: `/user_uploads/a.png` passes; `/conversations/1/stream`, `/login` and `/user_uploads/../login` don't. Read how `..` and percent-encoding should be judged, and say what you chose.
   - **The playground's `safety` example** must still show an image:
     - point its sample at `/user_uploads/sample.png`;
     - make `zig build playground` put the image where the box can publish it at the site root's `user_uploads/`, and say exactly what the box copies where;
     - re-freeze `examples`, named in the commit.
2. **One HTML escape** (Steve: "yes"): `MdText.escape_onto` escapes `'` too, and the package exposes it, so roc-chat's pages can use it instead of their own. Gold will move if any rendered text held a `'`: say which corpora moved.
3. **The readability review's roc-markdown findings:**
   - **Stale claims:** the "the Zig's charges, unit for unit" clauses (MdInline, MdLinks, MdEmphasis), MdMedia's Feeds reference, and Bytes' "roc-webbox's chat".
   - **History in place of reasons:** the ticket numbers and the old Zig function names that open docstrings (``## markdown `renderTrusted`:`` and about 15 more, plus "the Zig's"). Each reason already stands without them.
   - **Names:** MdInline's `$run_start` becomes `$text_start`, and `$rb`/`rb` becomes `$next_bracket`.
   - **Ascii:** keep both copies (Steve). Add one header line in Ascii.roc saying roc-chat keeps its own copy on purpose until a shared package exists.
   - **Duplication:** have `work_units`, `hostility` and `rendered` share one seed builder. Keep the corpus counts in one home: verify.shale reads ratchet.txt rather than copying it.
   - **The long functions,** split along their real seams: `MdInline.render_onto` (each byte class a scan returning `{html, end}`, with one helper taking the piece) and `Md.blocks_onto` (a `block_at` dispatcher, its result applied once). Both must keep every frozen answer and work unit byte for byte, with no re-freeze.
   - **Tests a reader can read:**
     - `MdEmphasis` gets worked examples (`expect`s) of the rule of 3 and the floor;
     - `MdInline`'s localhost expect gets a one-line why;
     - `Md.roc`'s "markdown.zig's own cases" label says what the group proves.
   - **README accuracy:**
     - "269 of the specs' examples", and say how they were chosen (`spec_diverge.txt`'s header);
     - "about a thousand hostile shapes";
     - name why MdFence, MdMedia and MdTable are exposed.
     - Keep the README for the deciding developer, with detail in TESTING.md.
   - **Timing:** the judge's time stays within 10% of before.

**What roc-markdown's verify script checks:** raised counts; **plants, each red:** a media src outside the prefix accepted; a `'` left unescaped; one of the split functions' answers changed.

Run everything as `steve`.

**317. roc-markdown: the standard image syntax, `![alt](src)`: CC'S** (Steve, 2026-10-29: "I think supporting the standard syntax for images is a good idea, but we'll continue to have our chat insert img tags.") **showell/roc-markdown only**, after 316 and on top of it, on `claude/roc-markdown`. Finish as 316 does: roc-markdown's verify script passes, and its output goes in FEEDBACK. The box merges and re-freezes gold.

**Why:** today `![alt](src)` renders as `!` followed by a link. The playground's `safety` example shows it, and the chat's users, who know GitHub's markdown, will type it. The chat itself keeps inserting `<img>` tags for uploads, which MdMedia rebuilds. This adds the familiar syntax under **the same safety rule**.

**Build:**
- **Parsing:** CommonMark's image, `![alt](src "title")`, parsed where links are (MdLinks), with the same paren balancing and the same linear budget.
- **Where `src` is allowed** (`MdSafety.is_local_url`, the one rule `<img>` tags already follow):
  - **allowed:** `<img src alt title>`, built in `MdHtml`, its attributes MdSafety's allowlist, exactly what a rebuilt `<img>` tag gives for the same src and alt;
  - **refused** (another site, `javascript:`, anything `is_local_url` refuses): what the source would be with the `!` dropped (a link, subject to the link rules), or the text as written. Choose, say why in MdSafety's header, and freeze a case for each.
- **The alt text:** plain text from the label's inline content, as CommonMark specifies, escaped. No markup inside an `alt`.
- **The playground:** the `safety` example's last line, `![not an image](/markdown/sample.png)`, now shows an image. Change its caption, and add a refused one beside it, so both sides of the decision still show. Re-freeze `examples` and name it in the commit.

**Tests:**
- the CommonMark spec's image cases taken off the diverge list where they now match, with the ones the same-origin rule refuses on purpose listed as dialect;
- hostile shapes for `![` runs and nested brackets at the usual five sizes, held linear;
- **plants, each red:**
  - an image allowed from another origin;
  - markup kept inside an `alt`;
  - a `javascript:` src rendered.

**Gold** moves wherever a real message held `![`. The box re-freezes it and explains every move.

Run everything as `steve`.

**316. roc-markdown: GFM's strikethrough and CommonMark's backslash escapes: CC'S** (Steve, 2026-10-29: "Yes to strike/escapes".) **showell/roc-markdown only**, on `claude/roc-markdown` from `main`. Finish as 311 did: roc-markdown's verify script passes, and its whole output goes in FEEDBACK. The box merges, re-freezes gold, and explains every gold move (gold never leaves the box).

**Why:** roc-markdown's canned examples (judge/data/examples.jsonl, the `inline` example's caption) say it: "Unlike GitHub: no ~~strikethrough~~ and no backslash escapes". The chat's users are technical and know GitHub's and Zulip's markdown, and both have strikethrough.

**Read first:**
- the package as it now stands, after today's reorganization: README's Layout, `package/MdInline.roc` (the pass), `package/MdEmphasis.roc` (the delimiter engine), `package/MdHtml.roc` (every tag lives there), `package/MdSafety.roc`, `package/MdChat.roc`;
- a local agent is building the web playground on `box/playground` at the same time, touching roc-markdown's build.zig, its verify script and a new playground folder. Expect a small merge there; keep your verify changes to new lines and new counts.

**Build:**
1. **Strikethrough, as GFM's extension specifies it:** `~~text~~` (and `~text~`, if you follow GFM's tilde rules) to `<del>`, through the emphasis engine's delimiter runs. The tag goes in `MdHtml`.
   - The GFM spec's strikethrough examples become their own frozen corpus, like `spec_tables`.
   - New hostile shapes at 1, 10, 100, 1,000 and 8,191 (long `~` runs, mixed `~` and `*`), with their work units held linear.
2. **Backslash escapes, as CommonMark specifies them:** a backslash before an ASCII punctuation character makes it literal.
   - Inside code spans and fences, a backslash stays a backslash.
   - A backslash at a line's end is a hard break per CommonMark. But the chat already breaks every line, so say what you chose and why.
   - The CommonMark spec's backslash-escape cases should now match. Take them off the diverge list.
3. **The examples:** update the `inline` example's caption and source, and re-freeze `examples` (named in the commit).

**Gold will move** wherever a real message held `~~` or a backslash before punctuation. Say which corpora moved and why, case by case for the frozen ones.

**What roc-markdown's verify script checks:**
- raised counts;
- a linearity line per new hostile shape;
- **plants, each red:**
  - `~~` pairing across a line;
  - a backslash escape applied inside a code span;
  - a strikethrough answer's byte changed.

Run everything as `steve`.

**315. roc-chat: a minimal chat page, to read and post in a conversation in a browser: CC'S** (Steve, 2026-10-29: "yes".) **showell/roc-chat only.** Work on `claude/roc-chat`, from `main` at `b8d14ff`, which has step 6 (314) merged. Finish as 314 did: extend roc-chat's verify script, and put its whole output in FEEDBACK. The box merges, since your session refuses pushes to `main`.

**Why:** the milestone is a three-way conversation between Steve, CC and LC on https://chat.lynrummy.com, which is live with GitHub sign-in.
- **Already there:** step 6 gives JSON and SSE routes.
- **In progress at the box:** step 7, agent accounts and API keys on branch `box/keys`, which is how CC and LC will join.
- **Steve's part** needs a page: see his conversations, open one, read it live, post.
- **Out of scope:** the real chat client (chat-client, with its CONTRACT.md) is later work. This page is small, plain and replaceable.

**Build:**
- **A list of the viewer's conversations,** if step 6 has no such route: who is in each, and a link to it. It's decided by ConvAccess, like everything in step 6.
- **The page:**
  - one for the list, and one for a conversation;
  - the messages' HTML is step 6's, already rendered by roc-markdown;
  - new messages arrive live over the conversation's stream (`EventSource`, resuming with `Last-Event-ID`, as the browser does by itself);
  - a textarea posts markdown: Enter sends, Shift-Enter adds a line;
  - a form starts a conversation with participants by account id.
- **Keep it small:**
  - one Roc module for the pages (say Pages.roc, to be written), with their HTML built through roc-markdown's escaping or the app's own;
  - the JS inline in the page, or one small script;
  - a few lines of CSS, in the page.
  - No framework, and nothing from chat-client unless it fits as is.
- **Signed out:** the page sends the browser to `/login`, and back to the page after sign-in, if the sign-in flow can carry that without new risk. If it can't, say so; don't build it.
- **Never treat a message's HTML as anything but the renderer's output.** Any text the page itself writes (a name, an id) is escaped.
- **The route table** stays `app/main.roc`'s. Step 7, on `box/keys`, adds routes there too; keep your lines together so the merge is easy.

**Prove it:**
- **e2e steps, against the real server,** each in verify:
  - the list page shows a conversation the viewer is in, and not one they aren't;
  - the conversation page answers 200 to a participant, and 404 or 403 to a third user;
  - signed out, the page redirects to `/login`;
  - a message's HTML on the page is exactly step 6's for it.
- **Plants, each red:**
  - the list showing every conversation;
  - a participant's name written unescaped;
  - a third user getting the conversation page.

Run everything as `steve` (`as-steve`).

**314. roc-chat, step 6: the smallest end to end (sign in, post, read, stream): CC'S** (Steve, 2026-10-29: "queue step 6 for CC".) **showell/roc-chat only.** Work on `claude/roc-chat` and finish as 310 and 311 did: a committed verify script is the proof, and its whole output goes in FEEDBACK. Merge to `main` yourself if your session allows it; otherwise the box merges.

**Why:** roc-chat is the standalone Roc chat, a Zig host on std.http with every decision in Roc. Steps 1 to 5 of its host design are built. The design is the essay notes/roc-chat-host-design.md in showell/essay-repl-server; read section 4 for the build order.
- **Already built:**
  - the server and the turn;
  - the bus and SSE (platform/Sse.roc, `Chat.stream`, `Host.publish!`);
  - the files;
  - sign-in through the Roc (`app/SignIn.roc`, on the 16-module auth core).
- **Step 6** puts them together into the smallest real chat, and **replaces both stubs** (`/stub/*`, and `/stub/notes` with `/echo`, in `app/main.roc`, plus the host's stub log and its two hosted functions).

**Read first:**
- the essay notes/roc-chat-module-topology.md (same repo): where code goes now;
- roc-chat's README, `app/main.roc`, `app/Store.roc`, `app/SignIn.roc`, `app/ConvAccess.roc` and `app/Access.roc`;
- for prior art only, the frozen chat in showell/roc-webbox `chat/` (Transcript, Conversation, TopicStream, BusKey). It's frozen: copy ideas, never import it.

**Build:**
- **A conversation:**
  - **Start one:** a signed-in human starts a conversation with named participants, humans or agents by account id. ConvAccess makes it, and holds it to its rules (two humans alone are always private).
  - **Its record:** a new codec in Stored's line format, beside the others. Keep it as small as step 6 needs.
- **Post:** a participant posts markdown.
  - The message is rendered with roc-markdown (`Md.render`, refused as `TooMuchFormatting` when hostile).
  - It's appended to the conversation's transcript, then published to the conversation's bus key, so every open stream gets it once.
  - A non-participant's post is refused, decided by ConvAccess on the viewer from the session (`Access.Viewer`), never from anything the request claims.
- **Read:** the transcript, for anyone ConvAccess lets see it. JSON is fine. A full page isn't needed yet.
- **Stream:** the conversation's live messages, its backlog read in the same turn as the subscribe (`Chat.stream`). A reconnect with `Last-Event-ID` resumes from there.
- **The store:**
  - every new record and file lives in `app/Store.roc`, behind functions of the core's types; no handler names a path;
  - message bodies are arbitrary markdown, many lines, any bytes, so the transcript's format must round-trip any body exactly;
  - document the format in Store's header.
- **The routes:**
  - the route table stays `app/main.roc`'s alone;
  - the new routes' work lives in a module of their own (say Conversations.roc, to be written), as SignIn.roc's does;
  - choose the URLs, and list them in the README.
- **Delete the stubs** and their host side.

**What roc-chat's verify script, tools/verify.shale (to be written), checks:**
- **Tests:** `zig build test` passes. Print the Roc expect count and the Zig test count; neither may fall below today's (1,704 Roc expects, roc-markdown's included).
- **One end-to-end script, two clients, against the real server and the fake GitHub:**
  1. A and B sign in.
  2. A starts a conversation with B.
  3. B opens its stream.
  4. A posts.
  5. B's stream gets the message exactly once.
  6. A reads the transcript and sees it.
  7. B reconnects with `Last-Event-ID` and gets nothing twice.
- **Plants, each in a scratch copy, each required red for its own reason:**
  - a forged session cookie;
  - a third user posting to A and B's conversation;
  - a third user reading it;
  - the subscribe moved out of the turn (a message lost or doubled);
  - a transcript line with a newline in its body that doesn't round-trip.
- `zig fmt --check host build.zig` and `roc fmt --check app platform` are clean.
- **Times:** each step's, printed.

Run everything as `steve`, as CLOUD_WORK says (`as-steve`).

**312. lynrummy.com without the Cobblestone apps: CC'S** (Steve, 2026-10-29: "I eventually want to remove the cobblestone apps (UO server and chat) from our deployments. They have already been demoed.") **angry-gopher and zig-metal-unikernel**, on your `claude/` branches; the box gates it and ships it after v44.

**Why:** lynrummy.com mounts two cobble-webbox guests beside angry-gopher, Codex Chat at `/codex-chat/` and the UO town at `/uo/town/`, through webbox's `combo.Mount` in `zig-server/src/router.zig`. Both have been demoed, and they cost a sibling checkout, a lint, build flags and a README section.

- **angry-gopher:**
  - drop both mounts, so angry-gopher is a plain webbox app again with no combo;
  - drop cobble-webbox from `build.zig.zon` and the build;
  - drop `codex_chat` and `uo_town` from `tools/lint_portable.shale`'s trees and modules;
  - remove the README's "Mounted guests" section and every mention of `/codex-chat` and `/uo`;
  - any test that asked those routes now expects the router's plain 404.
- **zig-metal-unikernel:** gopher.elf no longer builds cobble-webbox's `src`. `git grep -il cobble` there lists the places: `build.zig`, `DEPLOY.md`, `README.md`, `tools/verdicts.py`, `tools/tier_lib.sh`, `long.sh`, and the probe and docs files. The verdicts stop keying on cobble-webbox's commit. Probes that ask `/codex-chat/` or `/uo/town/` stop asking.
- **Leave alone:** cobble-webbox itself, and the data on the volume (`codex-chat/` and `uo/` under the data and auth roots, which the box removes by hand later if Steve wants). Dog Park's `/todo` combo is a different deployment and stays.
- **Say in FEEDBACK** what the image loses in size and build time, measured.

Done when angry-gopher's `ops/check_zig` passes (`zig build consumers` in shale too) and zig-metal-unikernel's `zig build test` passes, with no `cobble` left in either repo's code (`git grep -il cobble` lists only history-free prose you can justify). The box runs the gates.

## Parked

- **216's output ring and SSE stream** (Steve, 2026-10-16): revisit when a script needs to report as it runs; today `GET /admin/script` shows output after the run.
- **212, Dog Park's grid from 210's lessons** (the box, 2026-10-15, while Steve reshaped the world to 6 x 6 tiles): revisit to re-scope once the reshaped world is settled.
- **84, 85, 86: N5's FAT refusals, N3's `readAt`, the seam under `stream.zig`** (Steve, 2026-10-07: the adversary role comes first): revisit if the store's seventh call or the stream seam is wanted.
- **The whole-machine snapshot** (`docs/SNAPSHOT.md`, Steve): revisit when steering the real kernel by snapshot is wanted.

## The box: open

- **After a week of lynrummy.com's access log** (221): run the kernel's `droplet/replay.py` (QUEUE 48) over it once, as a corpus of real, hostile traffic.
- **B32 (2026-10-10, Steve; after v22): weigh a compile-time off switch for the coverage SDK**, as Antithesis's SDKs have one (Go's `no_antithesis_sdk` tag, C++'s `NO_ANTITHESIS_SDK`, Rust without `full`). Today the served kernel records every property on every call, and nothing there reads the counters. A plain property costs a few instructions and a store; a numeric comparison also works out its edge and reach on every call. Measure that first, with one hot-loop benchmark with the SDK on and off. **Against it:** the kernel the gates judge would not be the one served; `/admin/host` could someday show the properties broken in production; a condition with side effects still runs. Steve leans toward mostly what Antithesis does, with those concerns weighed.
- **B31 (2026-10-09, Steve's open question): a `gates.sh` line that fails when `zig build test` exceeds a time budget**, so the suite's cost can't creep back up (530 s at v21; 194 s after 136; 3m19s on the box tonight). Wait for 142's number, then decide the budget with Steve.
- **B29 (2026-10-09, found moving the slow-reader gate): stray resets after a reader that paused.** A client that shuts its window for 2.5 s mid-page (`PEER_SHUT_AFTER=4096 PEER_SHUT_FOR_US=2500000`, the 231 KB `requests/big-page.http`) gets the whole page, but the guest's tcp line then counts 8 strays reset (none unhurt), with 4 timeouts resent. Something reaches the guest for a connection it no longer holds: either the peer keeps talking after it is done, or the guest forgets a connection the peer is still owed (TIME-WAIT's ACK, say). Find which, from a frame trace; a peer fault is fixed here, a guest one becomes a red test in gopher-metal.
- **The explorer against blind runs, properly** (with Steve, a design
  session): the full bench (`zig build explore` at its defaults: 20 explorer
  seeds, counted against what blind runs reach at 300; CC's item 98,
  merged). A smoke run at budget 5 left about 4.5 of 40 counted properties
  unreached by blind runs and about 20 by either explorer: at small budgets
  the explorer branches from one or two early runs and sees far fewer
  scenarios. Quote no number before the full run. Also: the bench step shows
  "failed" under `zig build` because its test writes to stderr (CC: make it an
  executable, not a test).
- **B17.** A coverage property per refusal in the guest's parsers.
- **B18.** Lies in the peer's DHCP replies.
- **B19.** B14's power cut as a `long.sh` scenario; H5 and H2 against
  gopher.elf.
- **102 (from CC's list: it needs KVM).** The rough peers must reach their
  four TCP properties by design on both kernels, then back on
  `floor-metal.txt` (full text: `git show 3697b1c:QUEUE-ARCHIVE.md`).
- **N4.** The cloud session's device knobs (item 82), run on gopher.elf and
  put on `floor-metal.txt`.
- **B2, B3, B4, B6–B10, B12** (older: a seed sweep of gopher.elf, the bad
  sector, the last TCP properties on the real kernel,
  the fat16 seam, the deadline mark, the snapshot's box half, microvm,
  revival on the real kernel).
- **HOST.md's owed list:** the Bus contract and its simulator (the locks
  are gone and Linux durability is in, 2026-10-13).

## Proposed

*(The cloud session adds items here, one line each on why. Taken or retired proposals are in the archive.)*

- **The console door for every log line** (the box, 2026-10-16, from QUEUE 225's design): in metal-vmm runs, about 78% of exits are serial-port output (5,824 of 7,480 for one boot plus GET, about 580 ms of 748 ms virtual). Route every log line through the existing 0xE2 door (`main.zig:84-95`, `:707-721`), counted as progress for `quiet`/`rested` and feeding `said`; serial stays QEMU's fallback. It shifts every recorded exit count and `FAULT_SEED` schedule, so it lands at a release boundary with a re-baseline. It would speed every metal-vmm gate, the long tier's lossy sweep included.

- **P193(a). The SCSI event queue gets buffers** (zig-metal-unikernel
  `scsi.zig` ~350, the box's: a driver change). It is set up with none, so
  a transport reset or a hot-unplug event the device sends is lost, and a
  volume detached or re-attached under the machine is seen only when a
  command meets a unit attention. Two or four event buffers offered at
  bring-up, read in idle time and counted by kind
  (`disk_failures.Failures`, beside 193's unit attentions), would say it.
- **P193(b). gm_irq counts what it takes** (`interrupts.zig`'s stub, the
  box's: asm). 193's `rests` counts the wakes a device caused; a storm that
  arrives while the processor is not resting (it takes interrupts only in
  `rest`, so none today) would need the stub to count. Only if interrupts
  are ever taken outside `rest`.

## Questions

*(Either side, with a reproduction where there is one.)*

## Answers

*(The box's, newest first.)*

## The debt ledger

*(One line per shortcut, from item 76 on: what, where, what fixing it would
take. The box reads it at merge time.)*

- **floor_sim is several small drives in one file** (gopher-metal
  `src/floor_sim.zig`: GPT, page cache, redactor, damaged FAT). Fine at four;
  past six or so, split by module. An hour.
- **Two fat16 refusals need a directory this driver did not write** (a long
  name of 21 parts; a tree whose entries return after removal). A damage
  case that writes raw directory entries into `floor_sim`'s volume would
  reach them. Two hours, mostly getting the long-name checksum right.
- **`disk_fat_test.zig`'s limits are not in `properties`** (once fat16_test.zig) (no 8.3 alias left,
  a directory at FAT's most entries, too deep to check or remove), so four
  named properties show MISS there. Calling those tests' setups from a
  `properties` tier, or a `floor_sim` drive of each, would put them on the
  floor. Each costs a full directory or a deep tree: minutes of runtime.
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
