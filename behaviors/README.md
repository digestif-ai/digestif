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

## How the node calls a behavior

The node's preview and nightly note give the writer the digest lines on stdin (`node/web/sources.ml`,
`write`): with `DIGESTIF_WRITER` set to a program, the node runs it with no arguments, the lines
on stdin, one per line, and takes its stdout as the note. `extract` prints exactly those lines, so
a writer built here can be fed from either side the same way:

```sh
node behaviors/bin/extract.ts --sources sources.json | my-writer
```

Until the node gains a hook that spawns behaviors (#53, D4.1), a launchd agent runs the suite at
the member's fixed minute.
