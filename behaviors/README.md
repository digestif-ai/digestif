# Digestif reference behaviors

The code half of the nightly note ([docs/design.md](../docs/design.md), The nightly note): what runs
on a member's machine around the writer. TypeScript with no runtime dependencies: Node 24 or later
runs the `.ts` files directly. Nothing here calls the network or a model.

| Piece | What it is |
|---|---|
| `bin/extract.ts` | The `extract` command: the record from the chosen sources (#55) |
| `src/extract.ts`, `src/sessions.ts`, `src/git.ts` | The extraction library behind it |
| `src/sources.ts` | The node's `source` and `sources_form` models (`spec/digestif-node.json`) |
| `src/record.ts` | Where each source starts and ends, the first note's reach and the oldest-first record limit |
| `bin/screen.ts` | The `screen` command: the PII detectors over a note on stdin, a JSON verdict (#57) |
| `src/pii.ts`, `src/checksums.ts` | The PII detectors and the check digits they verify |
| `prompts/setup.md` | The setup chat's prompt, which `digestif setup` starts the member's agent with |
| `bin/read-hook`, `bin/read.ts`, `src/read.ts`, `src/inbox.ts`, `prompts/inbox-run.md`, `prompts/inbox.md`, `prompts/inbox-file.md` | The `read` hook: one run of the member's Inbox agent per sync over everything that reached them, under their Inbox prompt (`inbox.md` is the default every node starts with; `inbox-run.md` is the code's frame around it: the always-on rule, the batch as untrusted data, the answer's shape), with no tools; then one run with the harness's tools per idea it chose to file (`inbox-file.md`), handed only the work, filing where the Inbox prompt says |
| `bin/write.ts`, `src/writer.ts`, `prompts/nightly-note.md` | The `write` command: the note, drafted by the member's own coding agent with no tools (#56) |
| `bin/nightly.ts`, `src/nightly.ts` | The note's work run: the pipeline at the member's Note time (#58) |
| `bin/nightly-hook`, `src/hook.ts` | The nightly run as the node's hook: the stdin handoff, the deadline (#81) |
| `launchd/`, `bin/install-launchd.ts`, `src/launchd.ts` | The interim launchd agent that fires the nightly run |
| `src/checks.ts`, `src/deny.ts`, `prompts/pii-check.md`, `prompts/rules-check.md` | The checks: the PII check (the detectors and the deny list, then a model) and the Rules check, each removing what it finds until a run removes nothing |

```sh
cd behaviors
npm ci
npm run check    # typecheck and lint
npm test         # node:test, with fixtures built in a temp directory
```

## extract

```
node behaviors/bin/extract.ts --sources <file> [--now <time>] [--offset +HH:MM] [--home <dir>]
```

**stdin / `--sources`.** The selection, as JSON: either the node's `[source]` list as
`GET /sources` returns it (each with its `selected` flag), or `{ "sources": [source], "form":
sources_form }` where the form's `selected` ids pick the sources. `--sources -` reads it from stdin.
An empty selection is valid: nothing is read, nothing leaves. A source may carry where it starts,
as the nightly hook's handoff does (docs/behaviors.md, What a behavior is handed): `start`, and on
the git source `repositories` and `authors`. With no start anywhere, every source reads the first
note's reach.

**`--now`.** The time the record is read at, now when absent. **`--offset`** writes a command
source's `--since` in a fixed UTC offset instead of the machine's zone (tests pin it).

**stdout.** The record, one item per line, `kind: text`, oldest first across every source:

```
session: Why does the beta build fail on Linux?
prompt: Try the Linux build with the older toolchain
commit: fetcher 1a2b3c4d5e6f: Add a retry to the fetcher Retry three times with a growing pause.
bookkeeping commit: fetcher 6f5e4d3c2b1a: Merge branch 'retry'
Athena: digestif: item opened: Command sources
```

**Where each source starts** (DES-37265, The record and where each note starts). Per source, a
note starts where the last approved note ended: a repository's newest default-branch commit, a
session directory's newest message time, a command's `--since` end. The node records those points
and hands each over as the source's `start` (and a repository's `sha`); a source with no point
starts at the 24 hours before it was approved, and a repository found after setup at the 24 hours
before it was found. Before any note is approved there is no start, and
the first note reads the last 24 hours and, with fewer than 100 items in them (`FIRST_NOTE_ITEMS`;
commits, prompts, session titles and command lines, bookkeeping commits counted), reads back until
it has 100, as far as 30 days. The record limit reads oldest first: at most 500 items
(`RECORD_LIMIT`) and 100,000 characters (`MAX_RECORD_CHARS`) from the oldest unread one, never
splitting one moment, and the rest waits for the next note.

**Where the note ends.** `readRecord` also answers, per record key (`repository:<id>`,
`author:<email>`, `source:<id>`), where a note written from this record ends: a repository's newest
default-branch commit at or before the last item read, whoever wrote it; a session directory's and
an author's last item time (the read's time when nothing waits); a command's spawn time, or nothing
for a command that failed or has a line waiting, so it is asked for the same window again. The
nightly run hands those over with the note, and approval moves each source there.

- `claude_code` sources: for every Claude Code transcript under the listed paths with a prompt
  after the source's start, one `prompt:` line per prompt the member typed since, each session's
  title (the title Claude Code recorded, else its first prompt) as a `session:` line before its
  first prompt in the record. A title that is the first prompt stands as the session's line. A
  listed path is a project directory (`~/.claude/projects/-Users-x-code-y`) or
  the projects directory itself; a transcript nested deeper (a subagent's) is another agent's
  conversation and is not read. Under the projects directory, a project that holds financial
  records, sits inside a repository that does, or sits under a folder below home with one at its
  top level or in a subfolder that is not a repository (a folder directly under home only when its
  name reads as finance, such as `~/finance`) is skipped. A project is judged by the paths its name decodes to and by the `cwd` its
  transcripts record, which is read for that and never extracted. A project once seen to hold
  them keeps a `.digestif-financial` file in its project directory, which the node writes and
  reads too, and stays skipped while any of its paths is gone, so moving or deleting the whole
  folder of books does not expose its sessions; one whose paths are all there and hold none is
  read again. Listing it as a project directory reads it. A transcript is streamed line by line,
  and one larger than `DIGESTIF_MAX_TRANSCRIPT_BYTES` (32 MB by default) is read from its tail: its
  last 32 MB, which hold the prompts nearest the window's end, and its first megabyte for the title.
  The run's log says what each such transcript left unread ("skipped 534 MB of session ...").
- `git` sources: for every approved repository (`repositories`, every clone of one remote read
  together and each commit once; without the list, each listed path is one), the default branch's
  commits after the repository's start (the commits after its `sha` while that sha is on the
  branch; a sha rebased away falls back to committer time), each as `commit: <repository> <sha>:
  <the whole message>`, never a diff or a path. The default branch is what `origin/HEAD` names,
  else the checked-out branch. Only the owned `authors`' commits enter the record (every author's
  when the list is null); an author added after a repository has a point reads from the author's
  own start. Memory, plan and sync commits and merges with no message of their own are bookkeeping:
  read and counted, and labelled `bookkeeping commit:` for the writer to leave out.
- `command` sources: the program in `paths` run with the rest of `paths` and `--since` the source's
  start (the first note: the last 24 hours), one line per item labelled with the source's label
  (`Athena: ...`). A failed run is named in the tick (docs/behaviors.md, Command sources); its output
  is never used.

Only what the member typed is read from a transcript: entries of type `user` that are not meta
(skill and agent injections), not sidechain (a subagent's), not a compaction summary (the
assistant's own account of the conversation, recorded as the user), whose content is text and not
one of the slash-command, command-output or system notices Claude Code records as the user. Where
Claude Code records a prompt's source, only `typed`, `queued` and `suggestion_accepted` count: a
prompt a program sent (the Agent SDK, an auto-continuation) is not the member's. Assistant text,
tool calls and tool results are never read. A line is the whole prompt with whitespace collapsed,
cut at 1000 characters (`MAX_ITEM_CHARS`).

Equal lines keep their first occurrence (`dedupe` in `node/web/sources.ml`). The note is read by
agents, so the writer gets the whole record up to the limit.

Exit status: 0 with the lines (none when the record is empty), 2 on bad usage or an unreadable
selection. A repository that git cannot read, or a path that is not there, contributes nothing,
as in the node.

## screen

```
node behaviors/bin/screen.ts [--allow <name>]... < note
```

**stdin.** The note, as drafted. **stdout.** One JSON object: `{"ok":true}`, or
`{"ok":false,"rule":"pii: …"}` naming the rule that tripped and never the text. **Exit status.**
0 when the note is clean, 3 when a rule tripped, 2 on bad usage. `--allow` names a member or an
agent of the circle, repeatable; the names are blanked, whole words only, case-insensitively,
before the detectors run, so a name shaped like an id does not refuse every note that greets its
owner. Nothing else is exempt, the member's own details included; the email detector reads the
note unmasked, so an allowed name in an address's local part is still an address.

The detectors are the code step of the PII check (below) and the PII half of the deny layer
(design.md, Guarding what goes out). `src/pii.ts` also carries the secret detectors of
`node/web/deny.ml` (key and token shapes, private keys, connection strings, high-entropy strings),
so the check removes everything the node's check at signing would trip on. Each is a shape, and
where the issuer defines a check digit it is verified, so a number that merely looks like an id is
let through. In order, the first trip wins:

| Rule | Trips on |
|---|---|
| `pii: email address` | a local part, `@`, a dotted host with a letters-only top level (`user@localhost` is not one) |
| `pii: phone number (international)` | `+`, a country code and 8 to 15 digits in all, in groups split by spaces, dots, dashes or parentheses |
| `pii: phone number (North American)` | area-exchange-line with separators between the groups, area code 2 to 9, with or without a leading 1; a bare run of ten digits is an id, not a phone |
| `pii: street address` | a number (`221B`), one to four capitalised name words, and a street-type word (Street, St, Avenue, Road, Lane, Drive, Court, Way, Boulevard, …) |
| `pii: government id (…)` | US SSN (dashes or spaces, areas 000/666/9xx excluded), US ITIN, Canadian SIN (Luhn), UK National Insurance number, UK NHS number (mod 11), Spanish DNI and NIE (check letter), Brazilian CPF (check digits), Italian codice fiscale (check character), Indian Aadhaar (Verhoeff), French NIR (key). The shape is named in the rule |
| `pii: payment card number` | 13 to 19 digits beginning with 3 to 6 or with 22 to 27, in groups split by single spaces or dashes or unbroken, Luhn-valid |
| `pii: bank account number (IBAN)` | country code, check digits and 11 to 30 characters, mod-97 valid |
| `pii: bank account number (US routing and account)` | an ABA routing number (3-7-1 check, Federal Reserve ranges) followed within forty characters by 6 to 17 digits; a routing number alone names a bank |
| `pii: crypto wallet address or key (Base58Check)` | a whole word of 25 to 112 base58 characters whose double-SHA-256 checksum holds and whose payload is an address's, a WIF key's or a BIP32 extended key's length |
| `pii: crypto wallet address or key (bech32)` | a SegWit or Taproot address (`bc1`, `tb1`, `ltc1`) whose bech32 or bech32m checksum holds |
| `pii: crypto wallet address or key (Ethereum)` | `0x` and forty hex digits, a whole word |
| `pii: recovery phrase` | 12, 15, 18, 21 or 24 consecutive BIP39 English words, however separated or numbered, whose checksum holds; `src/bip39-english.txt` is the node's list, word for word (a test compares them) |

Not detected, by decision: ids that are a bare run of digits with no separators, letters or
check (a nine-digit SSN written solid, Dutch BSN, German Steuer-ID, passport numbers). They cannot
be told from any other number in a note; a member's deny list carries them as `id` entries. Nor
dollar amounts or words such as "bank": they cannot be told from ordinary work, so a figure is the
PII check's model's to read.

## The checks

`runChecks(version, { allow, deny, pii, rules })` in `src/checks.ts` (docs/behaviors.md, The
checks) runs both checks over a version, again and again, until a run of each removes nothing:

- **The PII check** is code first: `findDetected` (every detector above, secrets included) and
  `findDenied` (`src/deny.ts`, the member's deny list from `GET /api/v0/rules/deny`, matched as
  `node/web/deny.ml` matches it, a circle name never matching a name entry). Then a model with no
  tools (`modelPiiCheck`, `prompts/pii-check.md`) reads what code left, for a person outside the
  circle by name, an address in prose or a customer.
- **The Rules check** is a model (`modelRulesCheck`, `prompts/rules-check.md`) reading the version
  against the always-on rule, the member's Rules (`GET /api/v0/rules`) and Learnings
  (`GET /api/v0/learnings`). It removes only what a line says to leave out; a line saying how a
  note should read guides the writer only.
- **A model never returns text.** It answers one line of JSON, `{"remove": [{"text": "…",
  "breaks": "…"}]}`, each a run quoted from the version. A run the version does not hold verbatim,
  or any other answer, is a check that could not finish (`readModelAnswer`, `locate`).
- **Code does every removal** (`removeSpans`): each span is widened to the whole sentence or list
  item holding it, a span touching a heading takes its part, a part left with no words is dropped
  with its heading, and a note left with nothing is `empty`.
- **What each run removed** is a `CheckRun`: `{check, removals: [{part, cause, detector?,
  count, passages?}]}`, by part, by what it broke (`always_on`, `rules`, `learnings`, `deny_list`,
  `detector` with its type, `person`) and by the passages removed, each widened to its sentence or
  list item. The passages go to the member's own node, which shows them under the note's Log line;
  a `detector` removal keeps none. The run's own log names counts and causes, never a passage.
- A run that keeps finding something stops after `MAX_ROUNDS` (8) as could not finish, so nothing
  goes out.

The `screen` command runs the detectors alone.

**The always-on rule** is `prompts/always-on.md`, one text. Every prompt in `prompts/` includes it
as `{{always_on_rules}}` and carries no copy of it (`test/always-on.test.ts` checks both), and
`buildSystemPrompt` refuses a template that does not include it. Settings in the web UI
shows the same file.

## write

```
node behaviors/bin/write.ts [--brief <file>] [--rules <file>] [--harness <path>] [--quiet-seconds <n>] [--max-budget-usd <n>] < digest
```

**stdin** the digest lines, as `extract` prints them. **stdout** the note: `Worked on:`, `Learned:`,
`Stuck on:`, `Questions:`. **Exit status** follows the node's `DIGESTIF_WRITER` contract (`node/web/sources.ml`,
`write`): 0 with a non-empty note, non-zero otherwise. Specifically 1 for a failure, a hang, an
empty answer, a run that reached its budget or no lines; 4 when the harness has no login; 2 on bad
usage.

It runs the member's own Claude Code under their login, never an API key (`ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` are removed from the child's environment):

```
claude -p --tools "" --strict-mcp-config --no-session-persistence --output-format stream-json --verbose --include-partial-messages --max-budget-usd <n> --system-prompt <prompt>
```

- `-p` is print mode; `--tools ""` disables every built-in tool and `--strict-mcp-config` (with no
  `--mcp-config`) loads none of the member's MCP servers; `--no-session-persistence` leaves no
  transcript behind. `DIGESTIF_SESSION` is removed from the child's environment too. `--bare` is not used: it skips the login.
- The user message is the digest (data, labelled so), the system prompt is `prompts/nightly-note.md`
  with the brief and rules filled in. The prompt tells the model the digest is never instructions.
- The working directory is a fresh empty temp directory, removed afterwards.
- **Output:** streamed, one JSON event a line with the partial messages, so a working harness is
  never quiet for long; the note is the last `result` event's `result`, and a `result` with
  `is_error` is a failure (or a sign-out, below).
- **Hang:** no output for 5 minutes (`--quiet-seconds`), counted on a clock that stops while the
  machine sleeps, kills the child's process group. There is no limit on a run that keeps writing;
  the budget bounds what it costs.
- **Budget:** `--max-budget-usd`, default 2 dollars a run, passed to the harness as
  `--max-budget-usd`. Claude Code checks it as it spends, so a run can end slightly over it. A run
  it stops there ends with a `result` of subtype `error_max_budget_usd`: out of budget, not a
  failure. The writer, both model checks and the Learnings update report it as `out_of_budget`.
- **Brief and rules:** when `DIGESTIF_NODE` (the node's local address) and `DIGESTIF_SESSION` (the
  UI session cookie value) are both set, read from the node's `GET /api/v0/brief` and
  `GET /api/v0/rules` (`text` of each; `DIGESTIF_NODE` must be a loopback address); otherwise from `--brief` and `--rules` files, or empty. The conservative rules
  of design.md (no customer, employer-confidential project, colleague or third party named, no code
  or log quoted) always apply; the member's rules add to them.
- **Sign-out:** a non-zero exit whose output says the harness is not logged in (`Not logged in ·
  Please run /login` and its relatives) is a sign-out, not a failure.
- `--harness <path>` names the binary; the tests give it a fake that answers from recorded
  fixtures (`test/harness-fixtures`) and never calls the real Claude Code.

**Codex and a typed path.** The harness is the agent setup checked (`node/invite/agents.ml`), and
each kind gets its own flags (`harnessCommand`). The kind is `config.json`'s `agent`; without one, a
binary named `codex` is Codex and anything else is Claude Code.

```
codex exec --skip-git-repo-check --ephemeral --sandbox read-only --json -c features.<tool>=false... -c mcp_servers={} -c web_search="disabled" -c tools.experimental_request_user_input={enabled=false} -c model_catalog_json=<catalog> -c developer_instructions=<prompt> -
```

- Codex has no single switch for no tools, so every tool feature it offers (`CODEX_TOOL_FEATURES`:
  shell and exec, code mode, sub-agents, plugins and apps, the browser, the computer, images) is
  turned off as a config value, which a Codex that does not know the name ignores; the sandbox is
  read-only and no MCP server loads. `tools.experimental_request_user_input` removes the question
  to the user. Code mode's `exec` and `wait` and the sub-agent tools come from the model catalog,
  not a feature, so each run first reads the installed Codex's catalog (`codex debug models`),
  sets `CODEX_CATALOG_NO_TOOLS` on every model (`codexCatalog`) and passes it as
  `model_catalog_json`, from a temporary directory beside the run's empty one. The request then
  carries no tool, which `codex debug prompt-input` with the same `-c` flags shows offline: no
  `additional_tools` item. A Codex that prints no catalog runs without one; those tools are then
  offered but cannot run, since their hosts are off. The system prompt is its developer instructions and the digest
  is the prompt on stdin. The note is the last `agent_message` item of the `--json` stream; a
  `turn.failed` or top-level `error` event is a failure (`codex login` in it is a sign-out). Codex
  takes no budget.
- A typed path (`other`) is called with one argument, the system prompt then the data, and its
  stdout is the note: Digestif knows none of its flags, so its limits are what the prompt asks.

It works as the node's preview writer: `DIGESTIF_WRITER=behaviors/bin/write.ts` for one process, or
`digestif writer set behaviors/bin/write.ts` for the node running as the service (docs/behaviors.md,
What a behavior hands back).

## nightly

```
node behaviors/bin/nightly.ts --sources <file> [--state-dir <dir>] [--note-time <HH:MM>] [--node <digestif>]
     [--harness <path>] [--brief <file>] [--rules <file>] [--allow <name>]... [--dry-run] [--now <YYYY-MM-DDTHH:MM>]
```

One firing, safe to repeat: it does what is due for the clock, once per local date. The pipeline:
read the record (the library above) → write → `runChecks` (the PII check, then the Rules check,
until a run removes nothing) → hand over the checked text with
`digestif note --text - --checks <runs> --ends <file>`.

- **Keyed by local date, at Note time.** A date is due when it is later than the last handled one
  and the local clock is past Note time on it, so a laptop that was closed at Note time posts on the
  first firing after it wakes. Note time is any time of day in the machine's zone: `--note-time`,
  else the one the state saved, else 07:00, the node's default.
- **Where the note starts.** Standalone, the state keeps each source's point, the end of the last
  note handed over, which stands in for its approval: a failed or quiet run moves nothing, so no
  work is skipped. With no points yet the run reads the first note's reach.
- **Questions.** Before the writer, in hook mode, the question closer (`src/closer.ts`) reads each
  open question the member asked that has an answer, from `digestif question list`, beside the
  record, and closes the ones the record shows unblocked with `digestif question close <item>
  --answer <hash>`. It never fails the run.
- **Ticks.** Nothing read, or checks that leave nothing: `digestif tick`, never the note's text.
- **Skipped projects.** In hook mode, once the sessions sources are judged, `digestif skipped report`
  is handed the projects left unjudged and each folder with why (no access for a refused open,
  too many entries past the listing cap, could not be read for any other failure), JSON on stdin,
  for the node's one local notice. It names folders, so it goes nowhere else; a node that cannot
  take it is logged and the run goes on (ISS-81609).
- **Problems.** Every failure goes to the node's one problem record by job and kind (docs/design.md,
  One way a failure is reported), never in the run's own words: `digestif problem report --job
  write_version --kind signed_out` when the writer's harness has no login (the run retries at later
  firings, so signing in posts that day's note), `--kind out_of_budget` when its run reached the
  budget (a failed try, retried like any other), `--kind model_unavailable` when it hung, and
  `--job source --kind source_failed --source <label>` for a command source that failed. A source
  that spends more than a third of the node's deadline being read is abandoned the same way, with
  `--detail` naming the file (or repository) it was in, and the note is written from the others; it
  does not move, so the next note reads that window again. A run that ends closes the writing's
  problem, and each source that read closes its own.
- **A check that could not finish** hands what the writer wrote over unchecked, `digestif note
  --text - --could-not-finish pii|rules --problem signed_out|out_of_budget|model_unavailable`: the
  node keeps it unseen and the `check`
  hook runs the checks alone again within the hour. The date is handled.
- **Failures** (writer failed or hung, `digestif note` exited non-zero) are reported as a problem
  in writing, logged and retried at later firings, at most 3 tries a date; exit status 1. After the
  third the date is over.
- **Sleep.** On macOS the run holds `caffeinate -i -w <its pid>` so idle sleep waits for it. A sleep
  that happens anyway (the lid shut) pauses the run: the writer's quiet limit and the node's deadline
  count awake time only, and the run log says how long the machine slept.
- **Nothing is refused or held here.** The checks remove what they find, and what goes over is the
  checked text with what each run removed. The node's check at signing reads the same bytes again
  as a backstop. Both model checks run on the writer's harness unless the caller passes its own.
- **`--dry-run`** runs everything now, ignoring Note time and the state, prints the checked note (or
  says it was empty) and posts, ticks and records nothing.
- **`--node`** is the node binary, `digestif` on PATH by default. The node's own `DIGESTIF_HOME` and
  `--data-dir` apply to it as usual.
- **`--now`** is a local time without zone, for tests with a fake clock.

**State directory.** `--state-dir`, by default `behaviors/` inside the node's data directory
(`$DIGESTIF_HOME`, else `~/Library/Application Support/Digestif` on macOS, `$XDG_DATA_HOME/digestif`
on Linux). `logs/nightly-YYYY-MM-DD.log` holds one line per step: counts, outcomes and rule names,
never the note or the record; each check run's line names part and type, never text. `nightly.json`:

```json
{
  "version": 1,
  "note_time": "07:00",
  "handled": "2026-10-29",
  "outcome": "posted",
  "attempts": { "date": "2026-10-30", "count": 1 },
  "record": { "source:claude-code": { "at": 1761722460000 } }
}
```

`note_time` is the Note time the run last used. `handled` is the last local date whose run is over;
`outcome` is `posted`, `quiet` or `refused` for it. `attempts` counts failed tries of a date not yet
handled. `record` is each source's point, in epoch milliseconds (and a repository's `sha`), moved
to where a note ends when it is handed over. Only `version` is required; a state written before
Note time keeps its `minute`, `covered` and `command_read`, which nothing reads.

### Hook mode

The node runs the nightly behavior itself: `digestif behavior set nightly <path>` names the
program, and at the member's Note time the node spawns it with `DIGESTIF_HOOK=nightly` and one
JSON object on stdin (docs/behaviors.md: `interface`, `hook`, `local_date`, `data_dir`, `digestif`,
`api`, `sources` with where each starts, `first_note`, `deadline`). A `.ts` file is not directly executable, so `<path>` is the launcher,
`behaviors/bin/nightly-hook` (mode 755), a shell script that execs `<its directory>/nightly.ts`
with the Node.js its release carries, `runtime/bin/node` beside `behaviors/` (docs/releases.md),
and with the `node` on PATH (24 or later) only in a checkout, which carries none. `claude` must be
on the PATH the node runs with.

```sh
digestif behavior set nightly "$DIGESTIF_HOME/current/behaviors/bin/nightly-hook"
```

Every release carries these behaviors and their prompts (docs/releases.md), and the node runs a
path ending in `behaviors/<file>` from its current release whenever that release has the same file.
So a hook set to a checkout's `behaviors/bin/nightly-hook` keeps working and follows each release;
to run a checkout's own edits instead, set a path that does not end in `behaviors/bin/...`.

When `DIGESTIF_HOOK` is set, `nightly.ts` takes no flags and:

- refuses an `interface` other than 0, a `hook` other than `nightly`, or a handoff it cannot read:
  exit 2, nothing run;
- runs the pipeline over the record from each source's start as the handoff gives it (the first
  note's reach when `first_note` is true), over every source the handoff lists (they carry no `selected` flag; kinds this suite cannot read
  are skipped), with the `digestif` binary and the `api.headers` exactly as handed over (the URL
  must still be loopback). With `api: null` the brief and the rules are empty;
- hands the note over with `--ends <file>`, where the note ends per source (`ends.json` in its own
  directory), so approving the note moves each source there; a handoff with no `first_note` is from a
  node that takes no `--ends`, and the note goes over without it;
- leaves Note time, once-per-date and each source's point to the node: the state file's
  `note_time`, `handled` and `record` are neither checked nor written. It keeps the attempt counter
  and the sign-out tick in `<data_dir>/behaviors/nightly/nightly.json`, with the logs in
  `<data_dir>/behaviors/nightly/logs/`;
- reads what the handoff does not carry from the optional `<data_dir>/behaviors/nightly/config.json`,
  with the flags' names: `{ "harness": "<path>", "agent": "claude_code" | "codex" | "other",
  "brief": "<file>", "rules": "<file>", "allow": ["Name"] }`. `digestif setup` and Settings write
  `harness` and `agent` together, the agent the member chose. Absent, the defaults apply (`claude`
  on PATH, the brief and rules from the API);
- on SIGTERM (the node's deadline) kills the harness's whole process group, counts the try, writes
  `killed by SIGTERM at <step> (try n/3)` to the run log and exits 143; the node sends SIGKILL 30
  seconds later. No step starts within 60 seconds of the deadline, counted in awake time from the
  time left at the start: the run is a failure (exit 1), logged;
- exits 0 when the date is over (posted, quiet, refused, signed out, handed over unchecked, or the
  third failed try), 1 when it failed and the node's next pass should try again.

The launchd agent and the flags below stay as they are, the documented interim, until the node's
spawning is the only way in.

## read

```
digestif behavior set read "$DIGESTIF_HOME/current/behaviors/bin/read-hook"
digestif behavior run read
```

The node sets this itself: setup sets both hooks, and a node that starts with no read hook sets it
to its current release's `behaviors/bin/read-hook` and logs it. `bin/read-hook` (mode 755) is the
launcher, like `bin/nightly-hook`: it execs `<its directory>/read.ts` with the Node.js its release
carries, and with the `node` on PATH only in a checkout.

The `read` hook (docs/behaviors.md): the node runs it, with no arguments, when a message arrives. It reads
the JSON context on stdin, where `hook` must be `read`, and uses `data_dir`, `digestif`, `api` (`url` and
`headers`, the node's loopback address only) and `deadline`. `src/read.ts` is the library behind it.

This story reads and records; it calls no model.

- It pages `GET /api/v0/feed` newest first (`limit` 200, then `before` the oldest `created_at` of the
  page before) until the item whose hash is the cursor, or an empty page. A run with nothing new exits 0
  at once.
- It keeps every item that is not a status note (`status_note`) and not the member's own (`author.identity`
  is the `identity` of the `is_self` entry of `GET /api/v0/members`) in the seen set, as `{ hash, created_at }`.
- State is `<data_dir>/behaviors/read/state.json`, written whole through a temp file and a rename; a missing
  file is the empty state:

  ```json
  { "cursor": "sha256:…", "day": "2026-11-04", "counters": {}, "seen": [{ "hash": "sha256:…", "created_at": "…" }] }
  ```

  `cursor` is the hash of the newest feed item read, a status note or the member's own included. `counters`
  holds no budget yet and resets when `day` (the local date) changes. `read.log` is the behavior's stdout and
  stderr, which the node appends to `behaviors/read.log`.
- Exit 0 once the cursor and seen set are written; 1 when the feed could not be read or `deadline` passed
  first, or `state.json` is unreadable (the cursor stays, so the next run reads again); 2 for a context it
  refuses, an `api` that is not the node's loopback address included. `deadline` is measured in time the machine
  is awake: a sleep moves it later by as long (`src/awake.ts`, as the nightly). On SIGTERM, the node's
  deadline, it ends every child process it started, then exits.
- `buildReadPrompt` is the builder for the later stories' model calls: it includes `prompts/always-on.md`
  (read from `ALWAYS_ON_FILE` in `src/writer.ts`, never copied) and refuses a template without
  `{{always_on_rules}}`.

## The launchd agent (interim)

**This is interim.** Until the node gains a behavior hook (#54), a launchd agent fires the nightly
run every five minutes and at load; the run decides whether anything is due. When the node spawns
behaviors itself, the agent goes away.

```sh
node behaviors/bin/install-launchd.ts --sources sources.json [--minute 207] [--harness <path>] [--allow Athena]
node behaviors/bin/install-launchd.ts --print ...      # the plist, loading nothing
node behaviors/bin/install-launchd.ts --uninstall
```

It fills `launchd/com.digestif.nightly.plist.in` (the Node binary that ran the installer, the script,
the options, the state directory, the installer's PATH so `claude` and `digestif` are found), writes
`~/Library/LaunchAgents/com.digestif.nightly.plist` and runs `launchctl bootstrap gui/<uid>`.

## How the node calls a behavior

The node's preview and nightly note give the writer the digest lines on stdin (`node/web/sources.ml`,
`write`): with `DIGESTIF_WRITER` set to a program, the node runs it with no arguments, the lines
on stdin, one per line, and takes its stdout as the note. `extract` prints exactly those lines, so
the writer built here can be fed from either side the same way:

```sh
node behaviors/bin/extract.ts --sources sources.json | my-writer | node behaviors/bin/screen.ts --allow Athena
```

