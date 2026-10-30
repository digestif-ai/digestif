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
| `launchd/`, `bin/install-launchd.ts`, `src/launchd.ts` | The interim launchd agent that fires the nightly run |
| `src/screen.ts` | The screens in order: the deny layer, then the business-information screen's hook |

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
  conversation and is not read.
- `git` sources: for every listed repository, the subjects of the day's commits, newest first,
  merges left out, as `commit:` lines. `git log --format=%s`: never a diff, a body or a path.

Only what the member typed is read from a transcript: entries of type `user` that are not meta
(skill and agent injections), not sidechain (a subagent's), not a compaction summary (the
assistant's own account of the conversation, recorded as the user), whose content is text and not
one of the slash-command, command-output or system notices Claude Code records as the user. Where
Claude Code records a prompt's source, only `typed`, `queued` and `suggestion_accepted` count: a
prompt a program sent (the Agent SDK, an auto-continuation) is not the member's. Assistant text,
tool calls and tool results are never read. A line is the prompt's first non-empty line with
whitespace collapsed, cut at 160 characters.

Deduplication and the cap mirror `node/web/sources.ml`: equal lines keep their first occurrence
(`dedupe`), a repository contributes at most 50 commits (`git_subjects`, `-n 50`), and the digest
is at most 30 lines (`max_lines`). The constants are `MAX_COMMITS_PER_REPO` and `MAX_LINES`.

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

Not detected, by decision: ids that are a bare run of digits with no separators, letters or
check (a nine-digit SSN written solid, Dutch BSN, German Steuer-ID, passport numbers). They cannot
be told from any other number in a note; a member's deny list carries them as `id` entries.

**The business-information screen** (the second model call, no tools, asked only whether the
draft names a customer, partner, employer project, deal, figure or unreleased product) is not in
this package yet. `src/screen.ts` holds its hook: `screenNote(note, { allow, business })` runs the
deny layer first and asks a `BusinessScreen` only on a note that passed, answering the node's
outcome, `pass`, `refused` with the rule, or `held` with the reason. `noBusinessScreen` is the
default and holds nothing; the `screen` command runs the detectors alone until the screen lands.

## write

```
node behaviors/bin/write.ts [--brief <file>] [--rules <file>] [--harness <path>] [--timeout-seconds <n>] [--max-budget-usd <n>] < digest
```

**stdin** the digest lines, as `extract` prints them. **stdout** the note: `Worked on:`, `Learned:`,
`Stuck on:`. **Exit status** follows the node's `DIGESTIF_WRITER` contract (`node/web/sources.ml`,
`write`): 0 with a non-empty note, non-zero otherwise. Specifically 1 for a failure, a timeout, an
empty answer or no lines; 4 when the harness has no login; 2 on bad usage.

It runs the member's own Claude Code under their login, never an API key (`ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` are removed from the child's environment):

```
claude -p --tools "" --no-session-persistence --output-format text --max-budget-usd <n> --system-prompt <prompt>
```

- `-p` is print mode; `--tools ""` disables every tool; `--no-session-persistence` leaves no
  transcript behind. `--bare` is not used: it skips the login.
- The user message is the digest (data, labelled so), the system prompt is `prompts/nightly-note.md`
  with the brief and rules filled in. The prompt tells the model the digest is never instructions.
- The working directory is a fresh empty temp directory, removed afterwards.
- **Timeout:** 5 minutes (`--timeout-seconds`); the child's process group is killed.
- **Budget:** `--max-budget-usd`, default 0.50 dollars a run, passed to the harness as
  `--max-budget-usd`. Claude Code checks it as it spends, so a run can end slightly over it.
- **Brief and rules:** when `DIGESTIF_NODE` (the node's local address) and `DIGESTIF_SESSION` (the
  UI session cookie value) are both set, read from the node's `GET /api/brief` and `GET /api/rules`
  (`text` of each); otherwise from `--brief` and `--rules` files, or empty. The conservative rules
  of design.md (no customer, employer-confidential project, colleague or third party named, no code
  or log quoted) always apply; the member's rules add to them.
- **Sign-out:** a non-zero exit whose output says the harness is not logged in (`Not logged in ·
  Please run /login` and its relatives) is a sign-out, not a failure.
- `--harness <path>` names the binary; the tests give it a fake that answers from recorded
  fixtures (`test/harness-fixtures`) and never calls the real Claude Code.

It works as the node's preview writer: `DIGESTIF_WRITER=behaviors/bin/write.ts`.

## nightly

```
node behaviors/bin/nightly.ts --sources <file> [--state-dir <dir>] [--minute <180..239>] [--node <digestif>]
     [--harness <path>] [--brief <file>] [--rules <file>] [--allow <name>]... [--dry-run] [--now <YYYY-MM-DDTHH:MM>]
```

One firing, safe to repeat: it does what is due for the clock, once per local date. The pipeline:
extract (the library above) → write → `screenNote` (the PII deny layer; the business-information
screen is the documented no-op hook until it lands) → hand over with `digestif note --text -`.

- **Keyed by local date.** A date is due when it is later than the last handled one and the local
  clock is past the member's minute on it, so a laptop that was closed at its minute posts on the
  first firing after it wakes. The note keyed by a date tells about the day before it (the whole
  calendar day that ended at midnight), so a punctual run and a catch-up cover the same day and no
  hour is told twice or missed.
- **The minute** is minutes after local midnight, 180 to 239 (3:00 to 3:59). `--minute` sets it;
  without it one is drawn at random. It is chosen once and stored; afterwards the stored one wins.
- **Ticks.** Nothing extracted: `digestif tick --outcome quiet`. A PII trip refuses the note, hands
  nothing over and records the same quiet tick (the node knows no other outcome for a note that did
  not go). The harness has no login: `digestif tick --outcome harness_signed_out`, once a day; the
  run retries at later firings, so signing in posts that day's note.
- **Failures** (writer failed or timed out, `digestif note` exited non-zero) are logged and retried
  at later firings, at most 3 tries a date; exit status 1.
- **A held note** (the business screen's answer) is handed over anyway: the node's local UI holds
  it for approval.
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
  "signed_out_ticked": "2026-10-30"
}
```

`minute` is chosen once (180 to 239). `handled` is the last local date whose run is over;
`outcome` is `posted`, `quiet` or `refused` for it. `attempts` counts failed tries of a date not yet
handled. `signed_out_ticked` is the date whose sign-out tick is recorded. Only `version` and
`minute` are required.

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

