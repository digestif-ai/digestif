# Behaviors

The node holds no intelligence. The note and the read loop are behaviors: executables
`digestif run` spawns, the way a coding harness runs hooks (design.md, The agent is spawned, not
embedded). A behavior does the agent's work, usually by calling the member's own harness, and hands
its results back to the node. This page is the interface between the two, version 0.

## Hooks

| Hook | When `digestif run` spawns it |
|---|---|
| `nightly` | The note's work run: on the first pass at or after the member's Note time, any time of day in their time zone, on a local date no run has handled yet, unless a note waits. A laptop asleep at Note time runs it when it next wakes. Not spawned while the member is Paused or a note waits, since note time writes nothing then; spawned during Onboarding until there is a first note. A member who wants an earlier note moves Note time. |
| `read` | After a pass, while the member is Active, when a message from another member has arrived since the last read run that is not a status note: status notes are skipped in code and cost no model call. Messages that arrive while Onboarding or Paused are kept, and the first read run at Active reads them. A reader of the feed skips an item carrying `status_note` the same way. |
| `check` | After a pass that finds a version owing its checks (a member's edit, or the agent's own when a check could not finish as it was written) or an edit owing its Learnings update: the nightly's executable, with `hook` set to `check` and the versions in `edits`. A version handed over and not finished is handed over again at most once an hour; the note never waits for its Learnings. |

A pass is the sync `digestif run` makes every interval (300 seconds by default) and at once when the
machine wakes. Each hook runs at most once at a time: a pass that finds one still running spawns
nothing for it. A nightly run that exits 0 handles its local date (it handed over a note, had nothing to say, or
spent its own tries and said why). Any other end (a non-zero exit, a signal, the deadline) leaves the
date due, so the next pass runs it again; after 3 such runs the node gives up on the date and
reports a problem (docs/design.md, Stages and the status note) whose kind says how the last one
ended (`digestif behavior list` shows the last handled date).

## Setting a behavior

    digestif behavior set nightly /absolute/path/to/nightly
    digestif behavior set read /absolute/path/to/read
    digestif behavior unset read
    digestif behavior list
    digestif behavior run nightly

The path must be absolute and executable. `digestif behavior run <hook>` spawns the hook now, as
`digestif run` would, waits for it, and exits non-zero unless it exited 0; a nightly run counts
toward that local date as it would under `digestif run`.

## What a behavior is handed

The behavior is run with no arguments. Its stdin is one JSON object:

```json
{
  "interface": 0,
  "hook": "nightly",
  "local_date": "2026-10-29",
  "data_dir": "/Users/mike/Library/Application Support/Digestif",
  "digestif": "/usr/local/bin/digestif",
  "api": {
    "url": "http://127.0.0.1:7420",
    "headers": { "Cookie": "digestif_session=...", "Digestif-Local": "1" }
  },
  "sources": [
    {
      "id": "git",
      "kind": "git",
      "label": "Git repositories",
      "paths": ["/Users/mike/code/digestif"],
      "yields": ["Commit subjects from the last day"]
    }
  ],
  "deadline": "2026-10-29T03:47:00.000Z"
}
```

| Field | What it is |
|---|---|
| `interface` | This page's version. A field is added without a bump; one removed or changed bumps it. |
| `hook` | `nightly`, `read` or `check`. |
| `edits` | `check` only: each version as `{id, note_id, voice, text, checked, edited_text}`. `voice` is `person` for a member's edit and `agent` for the agent's own version whose checks could not finish; `text` is the words the checks run on, or the checked text once only Learnings are owed (`checked` true); `edited_text` is the checked text of the version the member edited. |
| `local_date` | The member's local date the run is for, `YYYY-MM-DD`. |
| `data_dir` | The node's data directory. |
| `digestif` | The binary that spawned the behavior, for `digestif note` and `digestif tick`. |
| `api` | The local API (`spec/digestif-node.json`) and the headers every request carries: a session that ends when the behavior exits, and `Digestif-Local`. `null` when the node serves no web UI (`--no-ui`). |
| `sources` | The sources the member chose, with absolute paths. Nothing else on the machine is the behavior's to read. |
| `deadline` | When the node ends the run (below). |

**Where each note starts.** A note covers no calendar day. Per source, it starts where the last
approved note ended: a repository's newest default-branch commit, a session directory's newest
message time, a command's `--since` end. A note fixes where it ends when it is written, and approval
moves each source to that point; a waiting or unwritten note moves nothing, so no work is skipped
and new work goes into the next note. A source with no recorded point (approved later, a commit
author added, a session directory or command added) starts at the 24 hours before it was approved.
The first note reads the last 24 hours and, with fewer than 100 items in them, reads back until it
has 100, as far as 30 days. The record limit reads oldest first, and the rest waits for the next
note. The record is full commit messages with repository and sha, session titles and prompts, and
command output, never a diff; bookkeeping commits (memory, plan and sync commits, merges with no
message of their own) are read and counted but left out of the note, and the writer tells each
piece of work once.

**A behavior's own files.** A behavior keeps what it needs between runs (its attempt counter, the
sign-out tick it recorded, its configuration: the harness to run) under
`<data_dir>/behaviors/<hook>/`, which is its own; the node writes nothing there and never deletes it.

The environment is the node's, plus `DIGESTIF_HOME` set to `data_dir`, so every `digestif` command
the behavior runs works on the same node, and `DIGESTIF_HOOK` set to the hook.

Nothing about the working directory is promised; use `data_dir` and absolute paths.

## What a behavior hands back

A behavior writes nothing into the node's database and signs nothing. It hands its results over:

- **The note**: `digestif note --text - --checks <runs>` with the checked note on stdin, after both
  checks have run on the writer's version until a run removes nothing (The checks, below). It
  becomes the note's first version, and it waits for the member, or is approved by the agent when
  auto approval is saved, and is signed and posted once approved. That records the run's tick. The
  agent approves with `--approve`, read from `GET /api/v0/settings/approval` at hand-over; the app's
  send job, on every pass, signs what is approved and unsigned, and a trip at signing returns the
  note to Waiting with the reason. A
  version the checks leave empty is not written, and the day takes the Nothing to share path.
- **A member's edit** (the `check` hook): both checks run on the edit's text exactly as on the
  agent's, and `digestif note checked <version> --text - --checks <runs> [--removed]` hands the
  result back, or `--could-not-finish pii|rules [--signed-out]` when a check could not. Once a
  version's checks pass, the agent reads the line diff between `edited_text` and the checked text
  (never what a check removed) and hands Learnings back whole with
  `digestif learnings set --version <version> --text -`. A Save & approve version goes out only if
  the checks removed nothing.
- **Every prompt** a behavior runs for a member includes the always-on rule,
  `behaviors/prompts/always-on.md` (docs/design.md, Guarding what goes out), and carries no copy.
- **A run with nothing in the record**: `digestif tick`. No note is written, and when the clock runs
  out the status note says Nothing to share today.
- **A failure** of any job a behavior runs is a problem, the one record every job's failure goes to
  (docs/design.md, One way a failure is reported): `digestif problem report --job <job> --kind
  <kind> [--source <label>]`, and `digestif problem resolve --job <job> [--source <label>]` when the
  job next succeeds. The jobs are `write_version`, `pii_check`, `rules_check`, `source` and
  `learnings`; the kinds `signed_out`, `model_unavailable`, `out_of_budget`, `source_failed` and
  `failed`. The same job and kind add to one open problem. The member sees it in the header of
  Notes and the note's Log; the circle sees only Could not run today. when the clock runs out. A
  command source that failed is a problem naming the source by its label, never its output. A run's
  own words stay in its log; nothing hands them to the node.
- **A check that could not finish on what the agent wrote**: `digestif note --text - --checks <runs>
  --could-not-finish pii|rules [--signed-out]` with the writer's version on stdin. The note is kept
  with that version unseen and unapproved, its Log says when the checks run again, and the `check`
  hook is handed it within the hour with `voice` `agent`: both checks run on it as on an edit, and
  `digestif note checked <version> --text - [--approve]` hands it back, `--approve` when auto
  approval is saved. The writing is never run again for it, and no Learnings come from it.
- **Everything else** goes through the local API at `api.url`: reading the feed and the brief,
  replying, proposing an ask. Every outbound message passes the deny layer there too.

The writer is the coding agent the member chose at install (docs/design.md, Flows), recorded in the
node's config with `digestif writer set <program>`, which is what a node running as the service
reads: `digestif service install` installs the service with the PATH of the shell it runs in, so a
`#!/usr/bin/env node` writer and the `claude` it runs resolve as they do there. There is no preview
note and no brief drafted on a page: the setup chat proposes the brief.

While it runs, the nightly behavior keeps `progress.json` in `<data_dir>/behaviors/nightly/` (`step`:
reading, writing or checking, and `sources`, their labels), which the first note's page shows.

## The checks

The note behavior runs both checks on every version it hands over (docs/design.md, Guarding what
goes out): `behaviors/src/checks.ts` is the reference.

- **The PII check** is code first, then a model. The code step removes every match of the built-in
  detectors (secrets, emails, phone numbers, government ids, card and bank numbers with their
  checksums, wallet keys, recovery phrases) and of the deny list's entries, read from
  `GET /rules/deny` and matched exactly as the node matches them at signing. The circle's member and
  agent names never match. Then a model with no tools reads what code left, for a person outside
  the circle by name, a street address in prose or a customer.
- **The Rules check** is a model reading the version against the always-on rule, Rules and
  Learnings (`GET /rules`, `GET /learnings`). **It deletes only for what a line says to LEAVE
  OUT.** A line saying how a note should READ (how to name a fix, what order to tell things in)
  guides the writer only and is never enforced by deletion, because deleting a span cannot make text
  read differently: enforced, a style line would delete every sentence written another way, the
  member's own edits included. A line that could be either guides the writer.
- **A model answers spans, and code deletes them.** Each check's model answers one line of JSON,
  `{"remove": [{"text": "...", "breaks": "..."}]}`, every `text` a run quoted from the version. A run
  the version does not hold verbatim, or any other answer, is a check that could not finish, and
  nothing goes out.
- **Code widens every span to the whole sentence or list item holding it before deleting**, so a
  removal never leaves half a sentence such as `Shipped the fix for .` in a note. A sentence ends at
  `.`, `!` or `?` followed by whitespace; a list item is its line and the indented lines that
  continue it; a span touching a heading takes its whole part.
- **An emptied part is dropped**, its heading included, and **a note left with nothing is not
  written**: the behavior hands nothing over and records `digestif tick`, the Nothing to share path.
- **The rerun.** After a run of the PII check and a run of the Rules check, both run again over the
  result, until a run of each removes nothing.
- **What goes over** is the checked text, `digestif note --text - --checks <runs>`, where `<runs>` is
  `[{"check": "pii" | "rules", "removals": [{"part", "cause", "detector", "count"}]}]`, one entry per
  run in order. Each removal names the part's heading and what was broken (`always_on`, `rules`,
  `learnings`, `deny_list`, `detector` with its type such as `API key or token`, or `person`),
  never text. The node keeps exactly those fields as the note's Log (`GET /notes/:id/log`) and
  refuses any other shape.

**The check at signing** stays, as a backstop that should never fire. The node runs the code
detectors and the deny list over the exact bytes it is about to sign, as it does for every
outbound message. A trip refuses to sign that version and never edits it: the note returns to
Waiting, an auto-approved one included, with the reason on its page (`Not sent. A deny list entry
matches Worked on. Edit it.`), the Log records `signing_refused`, and approving the same text is
refused the same way. **Replies and a person's own posts keep the deny layer** as their only check:
`digestif post` and `POST /messages` refuse a trip and never edit, a refused reply is kept as a
refused row naming the rule, and a refused post says so where it was written.

## Command sources

A command source is any program the member already uses (Athena, a notes app, a calendar) turned
into a source with no change to the node. The app tests it when it is saved: it runs the program with
`--since` a day ago, saves it only if that succeeds, and hands the agent a line count or the error,
never the output. The member adds one in the setup chat or on Settings, or with

    digestif source add --label Athena --command /usr/local/bin/athena -- activity --project digestif

Its `kind` is `command` and its `paths` are the program, by its absolute path, then its arguments.
A command source is tested when it is saved: the node runs it with `--since` a day ago, and saves it
only if it succeeds; the agent is given only the result, a line count or the error, never the
output. The contract:

| | |
|---|---|
| argv | the `paths`, then `--since DATE_TIME`: the start of the window, an ISO 8601 date time with the machine's UTC offset, such as `2026-11-01T03:50:00-05:00` (`+00:00` at UTC, never `Z`). A note passes where the last approved note's read of this source ended, and the 24 hours before the source was approved when there is none; the test when it is saved, a day ago. |
| stdout | one item per line, in plain words. Blank lines are skipped. |
| exit | 0 on success, including no lines. Any other exit, or a run still going after 30 seconds (it is killed), gives no lines and reports a problem naming the source. |
| stdin, environment | nothing on stdin; the node's environment. |

The start moves only when a note is approved, to the end that note fixed when it was written, so
a failed try, a note still waiting and a source that failed read the same window again.

The node bounds what it takes: at most 200 lines per source and 1000 characters per line, then
the same deduplication and record limit as every source. Each line reaches the writer as
`<label>: <line>`. The lines never leave the machine: they only feed the writer, and the note the
writer drafts passes both checks and waits for approval like any other. Removing a command source
(`digestif source remove command-athena`, or on Settings) removes only it; the sources the machine
discovers are never removed.

## Output, exit and the deadline

stdout and stderr are appended to `behaviors/<hook>.log` in the data directory, between the node's
own lines saying when it spawned the behavior and how it ended. `digestif run` prints the same end
line (`exited 0`, `killed by SIGTERM`) to its log.

A nightly run may take 30 minutes and a read run 15, counted in time the machine is awake: the node
adds up the time between its passes' checks, and a gap of more than a minute is the machine asleep,
a pause the run is not charged for. `deadline` in the context is that limit read on the wall clock
at spawn, so it moves later by however long the machine sleeps. At its deadline the node sends the
behavior SIGTERM, and SIGKILL 30 seconds later; it signals the behavior's own process, so a behavior that
starts a harness ends it on SIGTERM. When `digestif run` stops, it sends every running behavior
SIGTERM. A self-update waits until no behavior is running.
