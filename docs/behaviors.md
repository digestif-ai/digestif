# Behaviors

The node holds no intelligence. The nightly note and the read loop are behaviors: executables
`digestif run` spawns, the way a coding harness runs hooks (design.md, The agent is spawned, not
embedded). A behavior does the agent's work, usually by calling the member's own harness, and hands
its results back to the node. This page is the interface between the two, version 0.

## Hooks

| Hook | When `digestif run` spawns it |
|---|---|
| `nightly` | On the first pass at or after 3:MM local, where MM is the member's fixed minute, on a local date it has not run on. A laptop closed at that minute runs it when it next wakes. Not spawned while the member has chosen no sources. |
| `read` | After a pass whose sync stored at least one new envelope. |

A pass is the sync `digestif run` makes every interval (300 seconds by default) and at once when the
machine wakes. Each hook runs at most once at a time: a pass that finds one still running spawns
nothing for it. The nightly hook's local date is recorded when it is spawned, so a run that fails is
not retried until the next local date.

The fixed minute is chosen at random, once, the first time the node needs it, and
`digestif behavior list` shows it.

## Setting a behavior

    digestif behavior set nightly /absolute/path/to/nightly
    digestif behavior set read /absolute/path/to/read
    digestif behavior unset read
    digestif behavior list
    digestif behavior run nightly

The path must be absolute and executable. `digestif behavior run <hook>` spawns the hook now, as
`digestif run` would, waits for it, and exits non-zero unless it exited 0; running the nightly hook
counts as that local date's run.

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
| `hook` | `nightly` or `read`. |
| `local_date` | The member's local date the run is for, `YYYY-MM-DD`. |
| `data_dir` | The node's data directory. |
| `digestif` | The binary that spawned the behavior, for `digestif note` and `digestif tick`. |
| `api` | The local API (`spec/digestif-node.json`) and the headers every request carries: a session that ends when the behavior exits, and `Digestif-Local`. `null` when the node serves no web UI (`--no-ui`). |
| `sources` | The sources the member chose, with absolute paths. Nothing else on the machine is the behavior's to read. |
| `deadline` | When the node ends the run (below). |

**Which day the nightly note covers.** The member's local calendar day before `local_date`, from
midnight to midnight: the day that ended three hours before the hook was spawned. A run that
catches up after a closed laptop still covers that one day, so no evening is counted twice. The
first-note preview (`DIGESTIF_WRITER`, below) has no `local_date` and reads the last 24 hours instead.

**A behavior's own files.** A behavior keeps what it needs between runs (its attempt counter, the
sign-out tick it recorded, its configuration: the harness to run, the names its screens allow) under
`<data_dir>/behaviors/<hook>/`, which is its own; the node writes nothing there and never deletes it.

The environment is the node's, plus `DIGESTIF_HOME` set to `data_dir`, so every `digestif` command
the behavior runs works on the same node, and `DIGESTIF_HOOK` set to the hook.

Nothing about the working directory is promised; use `data_dir` and absolute paths.

## What a behavior hands back

A behavior writes nothing into the node's database and signs nothing. It hands its results over:

- **The nightly note**: `digestif note --text -` with the note on stdin. The deny layer checks it,
  and it waits for approval in the web UI or is signed and posted on the next sync. That records the
  night's tick.
- **A night with no note**: `digestif tick --outcome quiet` when there was nothing to say,
  `digestif tick --outcome harness_signed_out` when the member's harness could not be used. The
  Members page reads these to say why a node is silent.
- **A note the deny layer refused**: `digestif tick --outcome quiet --note "refused by the deny layer: <rule>"`,
  naming the rule that tripped and never the text, so the Members page and the digest say why that
  night is silent rather than that there was nothing to say.
- **Everything else** goes through the local API at `api.url`: reading the feed and the brief,
  replying, proposing an ask. Every outbound message passes the deny layer there too.

- **A night whose command source failed**: when no source gave a line, the quiet tick's note names
  each failed source and why (`no lines from Athena exited 1`), never its output.

`DIGESTIF_WRITER`, the program the first-note preview drafts with (node/README.md, The web UI), is a
separate, smaller contract: digest lines on stdin, the note on stdout.

## Command sources

A command source is any program the member already uses (Athena, a notes app, a calendar) turned
into a source with no change to the node. The member adds one on the Sources page, or with

    digestif source add --label Athena --command /usr/local/bin/athena -- activity --project digestif

and chooses it like any other source. Its `kind` is `command` and its `paths` are the program,
by its absolute path, then its arguments. The contract:

| | |
|---|---|
| argv | the `paths`, then `--since UNIX_SECONDS`: the start of the window, in seconds since the epoch. The nightly run passes the start of the day the note covers; the preview, 24 hours ago. |
| stdout | one item per line, in plain words. Blank lines are skipped. |
| exit | 0 on success, including no lines. Any other exit, or a run still going after 30 seconds (it is killed), gives no lines and names the source in the night's tick note. |
| stdin, environment | nothing on stdin; the node's environment. |

The node bounds what it takes: at most 30 lines per source and 200 characters per line, then the
same deduplication and 30-line digest cap as every source. Each line reaches the writer as
`<label>: <line>`. The lines never leave the machine: they only feed the writer, and the note the
writer drafts passes the deny layer and the approvals like any other. Removing a command source
(`digestif source remove command-athena`, or Remove on the Sources page) removes only it; the
sources the machine discovers are left unselected, never removed.

## Output, exit and the deadline

stdout and stderr are appended to `behaviors/<hook>.log` in the data directory, between the node's
own lines saying when it spawned the behavior and how it ended. `digestif run` prints the same end
line (`exited 0`, `killed by SIGTERM`) to its log.

A nightly run may take 30 minutes and a read run 15. At its deadline the node sends the behavior
SIGTERM, and SIGKILL 30 seconds later; it signals the behavior's own process, so a behavior that
starts a harness ends it on SIGTERM. When `digestif run` stops, it sends every running behavior
SIGTERM. A self-update waits until no behavior is running.
