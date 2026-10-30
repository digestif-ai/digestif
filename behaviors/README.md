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
(skill and agent injections), not sidechain (a subagent's), whose content is text and not one of
the slash-command, command-output or system notices Claude Code records as the user. Assistant
text, tool calls and tool results are never read. A line is the prompt's first non-empty line with
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
owner. Nothing else is exempt, the member's own details included.

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
| `pii: payment card number` | 13 to 19 digits beginning with 3 to 6, in groups split by single spaces or dashes or unbroken, Luhn-valid |
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

## How the node calls a behavior

The node's preview and nightly note give the writer the digest lines on stdin (`node/web/sources.ml`,
`write`): with `DIGESTIF_WRITER` set to a program, the node runs it with no arguments, the lines
on stdin, one per line, and takes its stdout as the note. `extract` prints exactly those lines, so
a writer built here can be fed from either side the same way:

```sh
node behaviors/bin/extract.ts --sources sources.json | my-writer | node behaviors/bin/screen.ts --allow Athena
```

Until the node gains a hook that spawns behaviors (#53, D4.1), a launchd agent runs the suite at
the member's fixed minute.
