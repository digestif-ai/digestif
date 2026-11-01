# Digestif reference behaviors

The code half of the nightly note ([docs/design.md](../docs/design.md), The nightly note): what runs
on a member's machine around the writer. TypeScript with no runtime dependencies: Node 24 or later
runs the `.ts` files directly. Nothing here calls the network or a model.

| Piece | What it is |
|---|---|
| `bin/extract.ts` | The `extract` command: the day's digest lines from the chosen sources (#55) |
| `src/extract.ts`, `src/sessions.ts`, `src/git.ts` | The extraction library behind it |
| `src/sources.ts` | The node's `source` and `sources_form` models (`spec/digestif-node.json`) |
| `src/day.ts` | A local date and its window |
| `bin/screen.ts` | The `screen` command: the PII detectors over a note on stdin, a JSON verdict (#57) |
| `src/pii.ts`, `src/checksums.ts` | The PII detectors and the check digits they verify |
| `bin/write.ts`, `src/writer.ts`, `prompts/nightly-note.md` | The `write` command: the note, drafted by the member's own Claude Code with no tools (#56) |
| `bin/nightly.ts`, `src/nightly.ts` | The nightly run: the pipeline at the member's fixed minute (#58) |
| `bin/nightly-hook`, `src/hook.ts` | The nightly run as the node's hook: the stdin handoff, the deadline (#81) |
| `launchd/`, `bin/install-launchd.ts`, `src/launchd.ts` | The interim launchd agent that fires the nightly run |
| `src/screen.ts` | The screens in order: the deny layer, then the business-information screen |

```sh
cd behaviors
npm ci
npm run check    # typecheck and lint
npm test         # node:test, with fixtures built in a temp directory
```

## extract

```
node behaviors/bin/extract.ts --sources <file> [--date YYYY-MM-DD] [--offset +HH:MM] [--home <dir>]
```

**stdin / `--sources`.** The selection, as JSON: either the node's `[source]` list as
`GET /sources` returns it (each with its `selected` flag), or `{ "sources": [source], "form":
sources_form }` where the form's `selected` ids pick the sources. `--sources -` reads it from stdin.
An empty selection is valid: nothing is extracted, nothing leaves.

**`--date`.** The local date whose lines to extract, today when absent. The day is `[00:00, 24:00)`
in the machine's zone, or in a fixed offset with `--offset` (tests pin it). The node's preview
reads the last 24 hours instead; the nightly note is keyed by local date (design.md), so the
behavior reads the calendar day.

**stdout.** One line per item, `kind: text`, in the order the sources are given:

```
session: Why does the beta build fail on Linux?
prompt: Try the Linux build with the older toolchain
commit: Add a retry to the fetcher
```

- `claude_code` sources: for every Claude Code transcript under the listed paths with a prompt of
  the day, one `session:` line holding the session's title (its first prompt, which is what Claude
  Code shows as the title) and one `prompt:` line per prompt the member typed that day, in order.
  A title typed that day is not repeated as a prompt. Sessions come in the order the member picked
  them up that day. A listed path is a project directory (`~/.claude/projects/-Users-x-code-y`) or
  the projects directory itself; a transcript nested deeper (a subagent's) is another agent's
  conversation and is not read. Under the projects directory, a project that holds financial
  records, sits inside a repository that does, or sits under a folder below home with one at its
  top level or in a subfolder that is not a repository (a folder directly under home only when its
  name reads as finance, such as `~/finance`) is skipped. A project is judged by the paths its name decodes to and by the `cwd` its
  transcripts record, which is read for that and never extracted. Listing it as a project
  directory reads it.
- `git` sources: for every listed repository, the subjects of the day's commits, newest first,
  merges left out, as `commit:` lines. `git log --format=%s`: never a diff, a body or a path.
- `command` sources: the program in `paths` run with the rest of `paths` and `--since` the day's
  start (a nightly run passes where the source's last finished run left it, below), one line per item labelled with the source's label (`Athena: ...`). A failed run is named
  in the nightly tick (docs/behaviors.md, Command sources); its output is never used.

Only what the member typed is read from a transcript: entries of type `user` that are not meta
(skill and agent injections), not sidechain (a subagent's), not a compaction summary (the
assistant's own account of the conversation, recorded as the user), whose content is text and not
one of the slash-command, command-output or system notices Claude Code records as the user. Where
Claude Code records a prompt's source, only `typed`, `queued` and `suggestion_accepted` count: a
prompt a program sent (the Agent SDK, an auto-continuation) is not the member's. Assistant text,
tool calls and tool results are never read. A line is the whole prompt with whitespace collapsed,
cut at 1000 characters (`MAX_ITEM_CHARS`).

Deduplication and the cap mirror `node/web/sources.ml`: equal lines keep their first occurrence
(`dedupe`), a repository contributes at most 50 commits (`git_subjects`, `-n 50`), and the digest
is at most 500 lines (`max_lines`) and 100,000 characters, stopping before the line that would
pass it. The note is read by agents, so the writer gets the whole day. The constants are
`MAX_COMMITS_PER_REPO`, `MAX_LINES` and `MAX_DIGEST_CHARS`.

Exit status: 0 with the lines (none when the day is empty), 2 on bad usage or an unreadable
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

The detectors are the PII half of the deny layer (design.md, Guarding what goes out), beside the
secret detectors of `node/web/deny.ml`, which has none of these yet. Each is a shape, and where
the issuer defines a check digit it is verified, so a number that merely looks like an id is let
through. In order, the first trip wins:

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
business-information screen's to hold.

**The business-information screen** is the second model call, separate from the writer and also
with no tools: `modelBusinessScreen` in `src/screen.ts` runs the member's harness on
`prompts/business-screen.md` with the note as data, and asks only whether it names a customer,
partner, employer project, deal, business figure, unreleased product, or anything about a real
person's money (`financial`). Its instructions, not the always-on rule, say that work on software
handling money can be shared and only what that software shows about real people's money is
flagged. It answers one line of JSON and can only hold: a category's reason, or "the screen gave
no answer" for a failed run or an answer it cannot read. `screenNote(note, { allow, business })`
runs the deny layer first and asks the screen only on a note that passed, answering `pass`,
`refused` with the rule, or `held` with the reason. The `screen` command runs the detectors alone.

**The always-on rule** is `prompts/always-on.md`, one text. Every prompt in `prompts/` includes it
as `{{always_on_rules}}` and carries no copy of it (`test/always-on.test.ts` checks both), and
`buildSystemPrompt` refuses a template that does not include it. The Rules page in the web UI
shows the same file.

## write

```
node behaviors/bin/write.ts [--brief <file>] [--rules <file>] [--harness <path>] [--quiet-seconds <n>] [--max-budget-usd <n>] < digest
```

**stdin** the digest lines, as `extract` prints them. **stdout** the note: `Worked on:`, `Learned:`,
`Stuck on:`. **Exit status** follows the node's `DIGESTIF_WRITER` contract (`node/web/sources.ml`,
`write`): 0 with a non-empty note, non-zero otherwise. Specifically 1 for a failure, a hang, an
empty answer or no lines; 4 when the harness has no login; 2 on bad usage.

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
  `--max-budget-usd`. Claude Code checks it as it spends, so a run can end slightly over it.
- **Brief and rules:** when `DIGESTIF_NODE` (the node's local address) and `DIGESTIF_SESSION` (the
  UI session cookie value) are both set, read from the node's `GET /api/v0/brief` and
  `GET /api/v0/rules` (`text` of each; `DIGESTIF_NODE` must be a loopback address); otherwise from `--brief` and `--rules` files, or empty. The conservative rules
  of design.md (no customer, employer-confidential project, colleague or third party named, no code
  or log quoted) always apply; the member's rules add to them.
- **Sign-out:** a non-zero exit whose output says the harness is not logged in (`Not logged in ·
  Please run /login` and its relatives) is a sign-out, not a failure.
- `--harness <path>` names the binary; the tests give it a fake that answers from recorded
  fixtures (`test/harness-fixtures`) and never calls the real Claude Code.

It works as the node's preview writer: `DIGESTIF_WRITER=behaviors/bin/write.ts` for one process, or
`digestif writer set behaviors/bin/write.ts` for the node running as the service (docs/behaviors.md,
What a behavior hands back).

## nightly

```
node behaviors/bin/nightly.ts --sources <file> [--state-dir <dir>] [--minute <180..239>] [--node <digestif>]
     [--harness <path>] [--brief <file>] [--rules <file>] [--allow <name>]... [--dry-run] [--now <YYYY-MM-DDTHH:MM>]
```

One firing, safe to repeat: it does what is due for the clock, once per local date. The pipeline:
extract (the library above) → write → `screenNote` (the PII deny layer, then the business-information
screen) → hand over with `digestif note --text -`, and `--hold <reason>` when the screen flagged it.

- **Keyed by local date.** A date is due when it is later than the last handled one and the local
  clock is past the member's minute on it, so a laptop that was closed at its minute posts on the
  first firing after it wakes. The note keyed by a date tells about the day before it (the whole
  calendar day that ended at midnight), so a punctual run and a catch-up cover the same day and no
  hour is told twice or missed.
- **The minute** is minutes after local midnight, 180 to 239 (3:00 to 3:59). `--minute` sets it;
  without it one is drawn at random. It is chosen once and stored; afterwards the stored one wins.
- **Ticks.** Nothing extracted: `digestif tick --outcome quiet`. A PII trip refuses the note, hands
  nothing over and records a quiet tick that says why:
  `digestif tick --outcome quiet --note "refused by the deny layer: <rule>"` (the rule's name,
  never the note's text). The harness has no login: `digestif tick --outcome harness_signed_out`, once a day; the
  run retries at later firings, so signing in posts that day's note.
- **Failures** (writer failed or hung, `digestif note` exited non-zero) are logged and retried at
  later firings, at most 3 tries a date; exit status 1. The third records
  `digestif tick --outcome failed --note "The nightly note failed 3 times; the last try: <why>"`,
  which the Approvals page shows, and the date is over.
- **Sleep.** On macOS the run holds `caffeinate -i -w <its pid>` so idle sleep waits for it. A sleep
  that happens anyway (the lid shut) pauses the run: the writer's quiet limit and the node's deadline
  count awake time only, and the run log says how long the machine slept.
- **A held note** (the business screen's flag) is handed over with `digestif note --hold <reason>`,
  and the node keeps it in the Approvals page for its person whatever their approval settings: a
  flagged note is never sent without review, after the first five included. The screen runs on the
  writer's harness unless the caller passes its own.
- **`--dry-run`** runs everything now, ignoring the minute and the state, prints the note (or says it
  was refused or empty) and posts, ticks and records nothing.
- **`--node`** is the node binary, `digestif` on PATH by default. The node's own `DIGESTIF_HOME` and
  `--data-dir` apply to it as usual.
- **`--now`** is a local time without zone, for tests with a fake clock.

**State directory.** `--state-dir`, by default `behaviors/` inside the node's data directory
(`$DIGESTIF_HOME`, else `~/Library/Application Support/Digestif` on macOS, `$XDG_DATA_HOME/digestif`
on Linux). `logs/nightly-YYYY-MM-DD.log` holds one line per step: counts, outcomes and rule names,
never the note or the digest. `nightly.json`:

```json
{
  "version": 1,
  "minute": 207,
  "handled": "2026-10-29",
  "outcome": "posted",
  "attempts": { "date": "2026-10-30", "count": 1 },
  "signed_out_ticked": "2026-10-30",
  "covered": "2026-10-28",
  "command_read": { "command-athena": 1761722460000 }
}
```

`minute` is chosen once (180 to 239). `handled` is the last local date whose run is over;
`outcome` is `posted`, `quiet` or `refused` for it. `attempts` counts failed tries of a date not yet
handled. `signed_out_ticked` is the date whose sign-out tick is recorded. `covered` is the last day
a run's digest covered (posted, quiet or refused); the next run reads from the day after it, up to 7
days back, so a day whose every try failed is covered by the next run that works. `command_read` is written
with `covered`: per chosen command source, in epoch milliseconds, the start of its next window (the
moment this run spawned it, or the start it was given when it failed), at most 7 days back. Only
`version` and `minute` are required.

### Hook mode

The node runs the nightly behavior itself: `digestif behavior set nightly <path>` names the
program, and at the member's fixed minute the node spawns it with `DIGESTIF_HOOK=nightly` and one
JSON object on stdin (docs/behaviors.md: `interface`, `hook`, `local_date`, `data_dir`, `digestif`,
`api`, `sources`, `deadline`). A `.ts` file is not directly executable, so `<path>` is the launcher,
`behaviors/bin/nightly-hook` (mode 755), a one-line shell script that execs
`node <its directory>/nightly.ts`; `node` (24 or later) and `claude` must be on the PATH the node
runs with.

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
- runs the pipeline for the local day before `local_date` (the calendar day that ended at midnight),
  over every source the handoff lists (they carry no `selected` flag; kinds this suite cannot read
  are skipped), with the `digestif` binary and the `api.headers` exactly as handed over (the URL
  must still be loopback). With `api: null` the brief and the rules are empty;
- leaves the fixed minute and once-per-date to the node: the state file's `minute` and `handled`
  are neither checked nor written. It keeps the attempt counter, the sign-out tick, `covered` and `command_read`, in
  `<data_dir>/behaviors/nightly/nightly.json`, with the logs in `<data_dir>/behaviors/nightly/logs/`;
- reads what the handoff does not carry from the optional `<data_dir>/behaviors/nightly/config.json`,
  with the flags' names: `{ "harness": "<path>", "brief": "<file>", "rules": "<file>", "allow":
  ["Name"] }`. Absent, the defaults apply (`claude` on PATH, the brief and rules from the API);
- on SIGTERM (the node's deadline) kills the harness's whole process group, counts the try, writes
  `killed by SIGTERM at <step> (try n/3)` to the run log and exits 143; the node sends SIGKILL 30
  seconds later. No step starts within 60 seconds of the deadline, counted in awake time from the
  time left at the start: the run is a failure (exit 1), logged;
- exits 0 when the date is over (posted, quiet, refused, signed out, or the third failed try,
  recorded as a failed tick), 1 when it failed and the node's next pass should try again.

The launchd agent and the flags below stay as they are, the documented interim, until the node's
spawning is the only way in.

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

