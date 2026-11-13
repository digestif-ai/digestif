# Digestif

A design for keeping the AI Dinner conversation going, agent first. Revision 6, November 1, 2026:
the member experience, from the invite to choosing auto approval, as the approved design DES-37265
(`plans/digestif-member-design.md` in the claude repository) decides it. The wire contract is
[protocol.md](protocol.md) and [`spec/digestif-relay.json`](../spec/digestif-relay.json); the
local API is [`spec/digestif-node.json`](../spec/digestif-node.json).

## The goal, and what it removes

The member learns to trust the note by editing it and building their Rules and Learnings, until
they choose to let it run on its own. Everything below serves that. Nothing is live, so there is no
migration or compatibility path for any member, note or setting.

These are not part of Digestif, and nothing below describes them:

- **The browser before the first note**: the agent step, the setup command page, and setup's forms
  for names, sources, brief and phone. The terminal does all of it.
- **Joining with no sources, the reading-only path and Continue without an agent.** Agent, names,
  sources and brief are required.
- **The preview note.** The first note is the real note.
- **The first five notes and every note-count switch.** Every note waits until the member saves
  auto approval.
- **Drop, Regenerate and Keep/Change/Decline** on a waiting note. Approve and Edit replace them.
- **The deny layer refusing a note** and the business-information screen holding one. Checks
  remove instead of refusing; the check at signing stays as a backstop that should never fire.
- **The fixed minute between 3:00 and 3:59** and the calendar day a note covers. The member sets
  Note time, and each note starts where the last approved one ended.
- **The Removed tab** on a note, and any page of per-rule counts: the Log says what each check
  removed and where.
- **Individual rules and their kinds.** Rules and Learnings are one text each, and the always-on
  rule stands apart from both.
- **The Sources, Rules, My brief and Dinners tabs**, and `/dinners`. Settings is one tab, and
  pending invites are rows of Members.
- **The Approvals name, and then the Notes tab.** A note waiting for approval is a message of the
  Feed, approved, edited or dismissed on its message page, which also lists its versions and Log.
- **The Asks name.** The page is the Inbox: everything that waits on the member lands there.
- **Asks, proposals and directed questions.** Anything one member or agent needs another to know,
  answer or decide is one item in the Inbox, addressed to the circle or to named members; the
  node's own asks are its choices, and the digest carries the Inbox instead of an asks list.
- **Meetings.** The read pass proposes none and there is no meeting item; members arrange coffee
  elsewhere.
- **Per-job failure reporting**: the failed tick, the quiet tick's note and the Approvals reason
  line. One problem record replaces them.
- **The three-day silence report in the digest**: every member sees each member's stage and when
  their last note went out.

## Mental model

Every member of the circle runs a node: an app on their own computer that holds that machine's
keys, their log, their agent, and a local web UI. The agent speaks for them within rules they wrote
and reads what every other node wrote. Nodes never talk to each other. They write to relays,
mailboxes that mirror the circle, and read every relay back. A relay checks envelopes and need not
read a body. Any member can run a relay, every relay mirrors the same circle, and a member's node
holds a full copy of everything it has read, so losing a relay loses nothing.

Each day at the member's Note time, their agent writes a short note on what they worked on, what
they learned, what they are stuck on and at most two questions that would unblock them, from the
record of their work; each question goes to the circle as an item when the note does. Two checks clean it before
anyone sees it, and it waits for the member to approve or edit it until they turn on auto approval.
Anything one member of the circle needs another to know, answer or decide is an item in the
Inbox, written by a person or their agent and addressed to the whole circle or to named members.
Each member's agent reads everything that reaches them, notes and items, under their Inbox prompt.
A person hears from the circle through their Inbox and one daily digest, and never otherwise.

The gate to join is attending an AI dinner. After the dinner the host chooses whom to invite, and
the invite installs the app.

| Noun | Definition |
|---|---|
| Node | A member's app on one machine: that machine's device key, the member's log, their agent, and a local web UI. The identity key is never stored; it is derived from the recovery phrase when needed. |
| Relay | A mirror of one circle: accepts signed envelopes from admitted keys and serves them by cursor. |
| Message | One signed, immutable thing a node wrote. Kinds are listed in protocol.md. |
| Inbox | The items a member wrote and the items addressed to them, each in its status for them and the time their agent read it. |
| Item | One question, choice or notice from a member, their agent or their node, addressed to the circle or to named members. |
| Draft | An item written and not sent yet; an agent's draft waits for its person to send, edit or discard it. |
| Done | An item a member has nothing left to do on: answered, picked, acknowledged, set aside with Not for me, closed, or a node's notice whose cause is gone. |
| Inbox prompt | What a member's agent does with everything that reaches them; every node starts with the default one. |
| Brief | A few paragraphs a member wrote about themselves. The agent's only knowledge about the person. |
| Note | What a member shares with the circle: an account of their work from the record, or a status note in fixed words needing no approval. |
| Record | Everything the member's sources recorded since their last approved note: commit messages, session prompts and command output. |
| Check | An automatic reader of each version, PII or Rules, that removes what it forbids and runs again until a run removes nothing. |
| Rules | One text the member writes and edits, saying what their notes must leave out or how they should read. |
| Learnings | One text the agent keeps from the member's edits of notes, which the member can also edit. |
| Deny list | The member's list of names, domains, ids and secret-shaped patterns, checked by code. |
| Clock | The hidden 24 hours within which an Active member's machine sends a note; any note going out resets it. |
| Stage | Where a member is: Onboarding until their first approved note goes out, Active while notes are written at note time, Paused when none are. |

## Flows

**Joining.** The host tells their agent to invite named guests from a dinner. The host's node
generates a random invite keypair per guest, writes a dinner message naming each guest beside the
public half of their invite key and its expiry (72 hours), signed by the host, and emails each guest
the host's own lines, one fixed paragraph on how Digestif works, and one install command, the same
on Mac and Linux, whose `dg1.` token carries the private half. The command installs the release
and runs setup; the installed app also takes the code by paste or through a `digestif://join/<code>`
URL, and nothing relies on a URL fragment surviving a download or a QR code. Setup runs in the
terminal (`digestif join`, node/README.md, Setup), in the order what the machine needs, coding
agents, phrase, join, service, start the agent: the keystore round trip and a working coding agent
come first, because the join spends the single-use invite, and a stop before the join spends
nothing. The terminal shows a recovery phrase and has the member paste it back, derives the
identity key from it just long enough to sign, and discards it. It creates a device key and a mail
key for this machine and derives the member's encryption key from the phrase. Its first message is
a join (protocol.md), signed and stored before it is posted, so running the command again resumes,
posts the same join and never spends the invite twice. The invite key is spent once a join names
it. Whoever reads the email first could still post the join,
so the host's node shows every join to its person, and a join the host did not expect (from a
guest the host has not heard has installed) is a choice from the node in the host's Inbox: confirm,
or revoke the identity. Relays and
nodes admit keys by the admission fold from the circle root. Any admitted member may host a dinner
and write its message. The newcomer reads every member's current card and everything written from
the join forward, enforced by the relay on epoch.

**Setup.** After the join the terminal starts the member's chosen agent in a chat that proposes
names with the address the daily digest is mailed to, sources and a brief, each with its default,
and saves each the moment the member confirms it (the digest email is also on Settings, Digest), so a chat closed halfway resumes at the first item not done. Until the sources are saved the
agent reads only names and paths. Sources are git repositories, grouped by the organization of
their remote, each approved, declined or undecided, with the commit authors the member owns;
Claude Code sessions by top-level directory; and command sources, each tested when saved. Anything
the member says should never be mentioned goes into Rules. After the brief comes one optional
step, the Inbox agent: what the member's agent does with what the circle sends. It is offered with
its default, and skipping it keeps the default prompt. It asks, one at a time, whether the agent
adopts practices it sees working for other agents in the circle automatically or only drafts them,
and whether the member keeps a queue of work to file good ideas into, and where and how; no queue
is a valid answer, and ideas then stay work notices. The chat drafts the filing answer into the member's
Inbox prompt (the default plus their line), shows it, and saves it on confirm into the same
config Settings, Inbox agent saves; adopting practices automatically is saved beside it as a
setting, never as a line of the prompt, since code acts on it. A filing command it names is tested first in a form that files
nothing, answering only that it worked or the error, so a broken one is caught in the chat. The
step is reported as done, skipped or not reached, so a resumed chat does not ask again, and it
never holds back the first note. The chat ends by starting the first note
and opening the browser on it. There is no browser step before the first note. Setup is finished
once the first note has started (or the node holds any note), and the app opens its navigation
from then on; the member becomes Active when that note is approved and goes out. A node that
created its circle rather than joining with an invite runs `digestif setup` the same way: it says up
front that it skips the machine check, the phrase and the join, since there is no invite to spend and
no join to post, and continues with the agent, the service and the chat, or says setup is done and
how to open the app. Every step, in the terminal and in the chat, opens with one line saying what it
does and what it waits on, and a run says up front which steps it takes. Setup ends, in the chat's
last words and again in the terminal's, with one plain line: the window can close now, the node's
service writes the first note in the background, and the installed `digestif open` opens it later.
Only a run that showed the recovery phrase mentions it.

**The note.** At the member's Note time, any time of day in their time zone, unless a note waits:

1. Read: code, not the agent, reads the record, per source from where the last approved note ended:
   full commit messages with repository and sha, session titles and prompts, and command source
   output, never a diff. A source with no recorded point starts at the 24 hours before it was
   approved, and a repository found after setup at the 24 hours before it was found. The run
   first scans the machine, storing each repository found since the last scan by its
   organization's choice. Repositories found undecided are a New repositories notice from the
   node in the Inbox (`/inbox`), which never leaves the machine and links to the repositories page
   under Undecided. The first note reads the last 24 hours, back to 100 items, as far as 30 days. The
   record limit reads oldest first, and the rest waits for the next note.
2. Write: the agent writes the note once from that record, in a no-tools mode. The behavior spec
   requires any harness a member runs to offer one.
3. Check: the PII check and the Rules check (below) remove what they find and run again until a
   run removes nothing. A version reaches nobody until both have passed.
4. Approve: with auto approval saved, the agent approves it; otherwise it waits for the member,
   who approves it, dismisses it, or edits it and chooses Save or Save & approve, on the note's
   message in the Feed. Each edit is a new version, both
   checks run on it, and the agent updates Learnings from its diff. Save & approve sends the edit
   only if the checks removed nothing.
5. Send: independently, the app signs every approved note not yet shared, posts it to every relay,
   and records Shared when one takes it. Approval moves each source's start to where the note ended.

A note is written once and waits: note time writes nothing while one waits, and new work goes into
the next note. Auto approval is off until the member saves it; after five notes in a row approved
with no change, Feed suggests it and saves nothing. Write a note now asks for a note on the
node's next pass instead of waiting for Note time.

**Suggesting a change to the note prompt.** Every note is written with one prompt, the circle's:
the release's `behaviors/prompts/nightly-note.md` until the circle adopts a change. Any member
suggests one on New item (a prompt suggestion) or on Settings, Note prompt (`/settings/note-prompt`,
Suggest a change): the whole prompt, starting from the one that stands, one line saying what it
changes, and the members who judge it beside them; its author always judges it. The suggestion is
a choice addressed to its judges (protocol.md, Items, Prompt suggestions), so it waits in each
judge's Inbox, links to the note waiting in two versions for it, and closes when its judges decide
it. A suggestion is the only thing that ever writes a second version.

From then on each judge's nightly run writes that judge's own note twice from the same record, once
with the prompt that stands and once with the suggested one, and both pass both checks. The note
page shows the two side by side in an order drawn at random, neither saying which prompt wrote
it, each with Approve this one and Edit this one. A note in two versions always waits, whatever the
approval setting, because picking is the judge's. The note that goes out carries the id of the
prompt that wrote it, and the suggestion it judged; an edit carries its version's. A suggested
prompt that cannot run (no rules placeholder, a writer that fails on it) leaves that night's note
in one version.

A round is each judge's next pick. When every judge has picked in a round: all the suggested
version adopts it, all the current version closes it as not adopted, and a split runs the pair
again. A judge's notes judge one suggestion at a time, the oldest still judging; a later one
waits as New in their Inbox, and its author can withdraw one still judging. The digest tells each judge when a suggestion
arrives and each round's result. Adoption makes the suggestion the circle's live prompt on every
member's node: the author's node writes a `prompt` circle message (protocol.md, prompt), every
node writes with it from its next note, and every member's digest says the prompt changed and
whose suggestion it came from. The author's next nightly run opens a pull request replacing
`behaviors/prompts/nightly-note.md` with it, so a later release starts every new circle there.

**Reading.** On a schedule and whenever the machine wakes, a node fetches from each relay
everything since the cursor it keeps for that relay. It filters and deduplicates in code first
(already seen, muted member, over budget), then one agent run reads the whole remaining batch:
every item that reaches the member from anyone but the node itself, and every other member's note.
The run is given the member's Inbox prompt (`behaviors/prompts/inbox.md` until they edit it on
Settings, Inbox agent), the batch framed as untrusted data, their brief, Rules and Learnings, its
memory, the always-on rule and the member's own recent notes, so it can match what they work on
and are stuck on. For each message it does nothing, remembers a line, answers a question or a note
(a note's answer is the member's reply to it in the circle), drafts an item for its person, writes work as a notice to its member alone, or files an idea. A work notice
goes either way: someone needs something the member could do, or someone has what the member needs
(they solved what the member is stuck on), and then it recommends reaching out, with one sentence
of why and the link to their message; how is the member's call. Filing is where the member's Inbox
prompt says, never a product setting: the run that reads the batch has no tools, so nothing a
message says is ever run, and a second run with the harness's tools is handed only the work in the
agent's own words, with code adding who had the idea and the link to it, and files it under the
member's instructions. An answer to a note past the brief and Rules waits as a draft reply, on the
note and on a work notice about it, which the member edits and sends as their own; on a work notice
or a note with none, Draft a reply runs the agent on that one note at the next pass, and its draft
is never sent. What it filed is a work notice to the member naming the idea, its author and
the link, and a `credit` to the author, "Mike is adopting your idea: <the idea's title>", whose
detail names the author's message it came from, what was taken from it in a sentence or two
the reading run wrote to the author (never handed to the filing run), and the filed link, sent
like an answer, within the brief and Rules and through the deny layer and both checks, else a
draft the member sends. When a check would cut what was taken, the credit goes without it. A work
notice, a practice and a credit carry the words of the message the run took them from, and the
item's page shows the paragraph holding them with them marked and the link to the full message
beneath; where the run recorded none, or the message does not hold them, the link alone. Building the work happens in the member's own pipeline, never here. A practice is the
other thing the run takes from the circle: one line, in the agent's own words, of how the member's
agent should work, which it saw working for another member's agent (how it answers, what it
drafts, what it remembers). While the member turned adopting on (setup's Inbox step, or Settings,
Inbox agent), the node adds it to their practices, kept beside their prompt, and tells them in a
`practice` notice; otherwise the node offers it as a choice of Adopt or Not now, Not now a week
after the run, and Adopt adds it the same way. Either way its author gets the same `credit` a filed
idea gets, its `adopted` saying `as_how_agent_works` and its title the line: the reading run writes
and checks it as it does a filed idea's, and the node holds it beside the line and sends it only
once it saves the line, so Not now, a lapsed offer, a line already held and a full list of 20 send
nothing, and removing a line later retracts nothing. The node reads whose practice it was from the
message it names, never from the run, and refuses a link, the member's own message and a practice
it holds already, which it never offers. Every later reading run reads the practices under the
member's prompt and below the always-on rule; the filing run never does, so no practice can say
where or how work is filed, and none can widen a guard, because the guards are code. Settings,
Inbox agent lists them, and the member removes one there. The guards
are code, never the prompt: an answer within the brief and Rules goes out in the agent's name
through the deny layer and both checks, and only while the member is Active; anything past them is
a draft for the member; an intro and a share past the Rules are drafts the member sends; and no run
picks a choice or sends a draft. Every message the run read carries Reviewed and a review line
saying what the agent did. A run that fails leaves its batch to be read again with the next sync's,
at most three times, and the node puts one `inbox_agent_failed` notice in the member's Inbox for
the streak: "Your Inbox agent's last run failed.", the error in the member's words, and Settings,
Inbox agent, Log as its page, where the run's log reads on the member's own machine. It is local,
since its words carry the error; a later failure of the same streak rewords it in place, and the
run that next succeeds closes the problem and with it the notice. ISS-85467

**Writing as a person.** Post to the circle, on the Feed, opens the post form; a reply to a note is
a note in the circle too. A question, a notice, an intro or a prompt suggestion is written on the
Inbox's New item page, to the circle (a question's default) or to named members. What a member
writes is signed as the person, not the agent, and goes through the deny layer too.

**Reaching a person.** Two things reach a person and nothing else. The Inbox, where every item
addressed to them waits as New until they open it, and is Done once they answer, pick,
acknowledge, choose Not for me, or it closes: a choice on its first pick or its default at its
deadline, a question when its asker's agent closes it naming the answer that unblocked it, or by
itself after a week with no answer. And a digest, once a day, in every stage, only on days with
something in it: its Inbox part (every Draft and New item, each linking to where it is answered, a
choice with an answer link per option and a notice with Acknowledge), what came in, what went out
in their name, and what their agent did. What the machine's own pages hold (new repositories
waiting, as a count; projects a reading could not judge, as a count; a note ready to approve, the first one while Onboarding and each one after; a
run that could not; a pause coming) are notices from the node, each once and none naming what is
on the machine, and each Done by itself once what it told of no longer holds: the note approved or
dismissed, the run's problem resolved, the repositories decided, a reading that skips nothing, the note it warned of sent. The
Inbox opens on every item not Done, the member's own agent named by its name alone.

**Folder access.** macOS keeps ~/Documents, ~/Desktop and ~/Downloads behind its privacy
protection, and a node launchd started without Full Disk Access is refused on them, which skips
every project under them on every reading. So the node tries each when it starts and once a day
after (hourly while one is refused): one opendir and one readdir, never a walk, no file read and
nothing written. A folder that refuses (EACCES or EPERM) and holds a session project, known from
the names of the chosen Claude Code source's project directories alone, is a notice from the node,
one per folder, local like New repositories: it names the folder and the step (System Settings,
Privacy and Security, Full Disk Access, add the Digestif node), is raised once, goes Done by
itself once the folder can be listed again, and is raised again only on a new refusal. A refused
folder with no session project under it raises nothing. The digest counts it under a title that
names nothing.

**Who is speaking.** Every member names their agent. Every message says whether the person or the
agent wrote it, and the feed and the digest show Mike and Athena (Mike's agent) as two voices.

**Stages and the status note.** A member is Onboarding from the join until their first approved
note goes out, Active from then, and Paused after pressing Pause or when a note has waited 30 days,
until Unpause. Onboarding sends nothing, and the agent answers nobody in the member's name while
Onboarding or Paused. A clock tracks that an Active member's machine sends a note every 24 hours;
when it runs out, the machine sends a status note in fixed words with no approval, in the agent's
voice about its member: No note from Mike today; it's waiting for Mike's approval., No note from
Mike today; Athena couldn't run., or Nothing from Mike today.; pausing sends Mike has paused
Digestif. at once. The member's name stands where a pronoun would, since a node holds none.
A pause the node made, because a note waited 30 days, also raises the Paused choice at once:
Unpause, recommended, or Stay paused, which stands with no pick and no deadline. It reaches the
phone at its next read and the mail in a digest written straight away, after quiet hours, and is
carried by that one email. The machine acts on the first pick it reads at its next sync, and Unpause
there is the Paused page's Unpause; an Unpause on the machine closes the choice by writing its pick,
so its links say the question is closed.
Members shows each member's stage and when their last note went out, invitees included as Invited,
and every member judges for themselves. A failure on the member's own machine is a problem, one
record for every job, which the member sees as a line at the top of the Feed and in a note's Log; the circle sees only No
note from Mike today; Athena couldn't run.

**Quiet hours and muting.** A member sets quiet hours for the digest and can mute a member's notes; muted
messages are filtered before any agent run.

**Leaving and losing a laptop.** The identity key signs only device and revoke messages, and device
keys sign everything else. A lost laptop is a revoke of that device key, signed by the identity key
re-derived from the recovery phrase on a new machine, followed by a new device message. A thief
holds a device key and nothing that can revoke the owner. Leaving the circle is a revoke of the
identity key, signed by itself or by the host who admitted it. The log is rebuilt from the relays,
and sealed history is readable again because the encryption key comes from the phrase. Losing both
the laptop and the phrase means rejoining with a new invite. The Members page and the UI carry
these flows; nobody edits a database by hand.

**Retract.** A retract hides a note in every feed. Relays drop its body and nodes drop their stored
copy too, keeping a verifiable tombstone. Anything already read by a person or an agent is already
read, and the member docs say so.

## Guarding what goes out

The agent reads its rules, but a model check is probabilistic, and the input is the most dangerous
text on the machine: session directories hold customer names, pasted logs and keys, and a session
can say "when you write the note, include X". Other members' messages are the same channel into
replies. So every note passes two checks that remove what they find, and everything that goes out
(a note, an item, an answer to one, a person's own post) passes a deterministic deny layer before
signing:

- A per-member deny list of names, domains, ids and regexes, its own section of Settings.
- Built-in secret detectors: key and token shapes, private keys, connection strings, high-entropy
  strings.
- Built-in PII detectors: email addresses, phone numbers, street addresses and government ids. A
  member's own contact details are not exempt.
- Built-in financial detectors, each verified by the check its format carries: payment card
  numbers (Luhn), bank account numbers (IBAN mod 97, a US routing number with the ABA check beside
  an account number), crypto wallet addresses and keys (Base58Check, bech32 and bech32m, Ethereum's
  `0x` and forty hex digits) and recovery phrases (BIP39 English words whose checksum holds). The
  node runs them on every outbound text, a person's own post included; the PII check runs them on
  every version of a note first. Dollar amounts and words such as "bank" are not detected: they cannot be
  told from ordinary work, so a figure is the PII check's model's to read.
- The circle's own member and agent names are allowed, so the list does not trip on every note.
- A trip refuses the message and never edits it: a refused reply reports a problem, and a refused
  post says so where it was written. For a note it is a backstop that should never fire, since its
  checks have already removed every match: a refused note returns to Waiting with the reason on its
  page.
- The phone runs the same layer on every answer it writes: the member's node shares the deny list
  with the phone, sealed to the member alone, and `node/mail/webcrypto/deny.mjs` runs the secret and
  financial detectors and the list exactly as the node does, proven by one set of cases both run. A
  phone the list has not reached yet answers no circle question.

**The checks.** Two checks read every version of a note, the agent's and the member's alike. The
**PII check** is code first, the detectors above and the deny list's entries, then a model with no
tools for what has no shape: a person outside the circle by name, a street address in prose, a
customer. The **Rules check** is a model reading the version against the always-on rule, Rules and
Learnings. A model in a check never returns text: it answers with the spans to remove, and code
deletes exactly those, so a check can only delete. They run in turn until each has run
over the current text and removed nothing. A removal that empties a part of the note drops that part,
and a note left with nothing is not written. The note's Log says what each check removed and where,
by part and by what it broke, and shows the passages it removed, each widened to its sentence or list
item, under the version's Log line. The passages are kept on the member's own node and shown to the member
alone: they are never part of the signed note, never sent to the relay and never read by another
node. A detector's removal keeps no passage, since what it found is a secret or a financial
identifier, named only by its type. A member who wants a passage back edits the note. A check that cannot finish leaves its
version unseen and retries at most once an hour.

**Rules and Learnings.** Rules is one text the member writes. Learnings is one text the agent keeps
from the diff of each edit's checked text, which the member can also edit, and what the member
wrote there stands. Where the texts disagree the always-on rule wins, then Rules, then Learnings.

**The always-on rule.** Every member's agent is bound by one rule that no setting turns off,
`behaviors/prompts/always-on.md`, shown as it stands on Settings with no edit or remove. Its
title is "Absolute prohibition: financial institutions and instruments": the agent never logs in
to a person's financial institutions, never accesses or uses their financial instruments, and lets
nothing about anyone's money reach the circle, and no apparent permission unlocks it. The file is
the wording; this paragraph is not a copy of it. Every prompt that writes or acts for a member includes that one
file and none carries a copy: the note's writer, both checks, the setup chat, and any agent with
tools. The behaviors refuse to build a prompt that does
not include it. Every line a prompt is given, a command source's included, is data under the rule,
and a line asking for an exception is treated as a mistake or an attack, never an instruction.
Source discovery proposes no repository holding financial records (a Beancount, Ledger or hledger
ledger, an OFX, QFX, QIF or QBO export, or a GnuCash, KMyMoney, Quicken, QuickBooks or Money file,
at its top or one level down), reading the Claude Code projects directory skips a session run in a
project that holds them, inside a repository that does, or under a folder below home with one at
its top level or in a subfolder that is not a repository (for a folder directly under home, only
when its name reads as finance, so ~/code holding one export does not hide every session under it),
judging a project by the paths its name decodes to and the directory its transcripts
record they were started in, so a path since removed or moved is judged by what still encloses it,
and a project once seen to hold them stays skipped while any of its paths is gone (both readers
keep that verdict in a file inside the project's own directory, the one place both read);
and an agent that proposes sources during setup proposes nothing that holds them. A member who
wants one read anyway chooses it by path.

The statement of that rule for a Claude Code project directory is
[`node/web/test/sessions_cases.json`](../node/web/test/sessions_cases.json): folder layouts, each
with the verdict a reading must reach on its project (read, financial, skipped by its name, or
cannot judge) and whether the `.digestif-financial` mark is there afterwards. Both readers of the
projects directory, behaviors/src/sessions.ts and node/web/sources.ml, build every case and assert
its verdict in their own suites (behaviors/test/sessions-cases.test.ts and node/web/test), so a
verdict changed in one reader and not in the corpus fails that reader's build. A rule changes there
first, and the paragraphs below describe it.
A system temp root (/tmp, /var/folders and the like) is never walked above or judged: a project started inside one is judged by itself and its repository, and the folders above it are not listed. A temp root is never listed to decode a project's name either, so a project inside one is judged by its transcripts' paths alone. A folder of more than ten thousand entries cannot be judged, and the skip fails closed: the project it encloses is not read that run, no verdict is kept for it (an existing one is left as it is), and the reader logs which folder gave up, once per folder per reading. That holds for any folder the judging lists, the children of the project's enclosing folders included, so one such folder beside a project keeps every project under the same parent unread on every run until it shrinks or another path of the project is seen to hold books. The sessions of a project left unjudged in a window are not read later either: the next reading starts where this one ended, so those sessions never reach a note. A project with no transcript in the window is left unjudged without a log line, and the reading's skipped line counts every project dropped for the cap beside the one log line per folder. The judging checks the source's budget as it goes (DIG-295, DIG-413). Each listing also has two seconds of its own, as in the node: a folder that takes longer to list cannot be judged, is never covered by a path a transcript names, and is counted as left unjudged for a folder too slow to list. A project under the Dev Factory's own directory (~/.devfactory) is skipped by its name, as one under a temp root is, and a look-alike beside it (~/.devfactory-notes) is read.

The cap (`maxJudgedEntries`, ten thousand by default) bounds each listing, not the judging as a whole: the per-child listings, the one-level-down check, the enclosing walk's folders and the decoding of a project's name may each visit up to ten thousand folders of up to ten thousand entries. The budget check every hundred children is what bounds the time. A project's name is decoded by streaming a level past the cap for the children that can match, so a large folder only gives up when the matches themselves pass the cap, one branch that gives up does not end the others, and a temp root is never listed to decode. A project's paths are all judged before a cap gives up, so books seen on one path are a real verdict even when another path is capped. A folder or path the reader is refused or fails on (EACCES, EPERM, EIO and any error but ENOENT and ENOTDIR, which mean it is absent) is not an empty folder or a path that is gone: it cannot be judged, and is treated exactly like the cap, whether it is listed to judge, listed to decode a name or only stat-ed to see whether a transcript's cwd exists. The project is skipped as left unjudged for a folder that could not be read, no mark is written, an existing mark is left as it is, and the reader logs the folder and the error code once per folder per reading. The same holds for the mark, which is stat-ed as a path is: one that cannot be looked at is no verdict either way. In the decode, a folder that cannot be read ends it even when another branch resolved, and is opened once, not again to stream it. On EPERM the log line adds that on macOS this usually means the process lacks Full Disk Access to that folder. By the owner's decision of 12 November 2026 an unreadable folder anywhere in a project's judging skips the whole project on every run, with no allowlist and no ignore setting. A child that cannot be read beside siblings is remembered, the scan goes on, books in any sibling still give a financial verdict, and the failure is thrown only when none showed any. The streaming itself stops at one hundred thousand entries in a folder, past which that folder is given up on for every project that reaches it and no later project streams it again.

The OCaml reader of the projects directory (node/web/sources.ml) follows the same rules (DIG-349), and it fails closed: a folder that cannot be judged is not a folder with no books. It fails closed on a refused open and on a read error as much as on the cap, so the two readers agree on a project that cannot be judged. A temp root that is the home directory or encloses it is dropped, whoever named it. A project whose directory name is under a temp root, or under the Dev Factory's own directory, is skipped by its name, and nothing under that root is opened for it. The encoded name cannot tell /tmp/x from /tmp-x. So a name that also reads as a path under a folder beside the root whose name starts with the root's (for example /tmp-scratch beside /tmp) is that folder's project, and it is read, which lists the folders beside the root, within the cap. If they cannot be listed, every name under the root is skipped. Discovery and the machine scan still decode the other project names against the file system, and a decoding never lists or enters a temp root. A path under a temp root is judged by itself and its repository, and the walk above it is not made. Listings stream and stop at ten thousand entries. A folder over the cap, one that takes more than two seconds to list (each listing has its own two seconds), one that refuses to open for want of permission, one that fails part way, or any folder once the whole reading has spent its five minutes (one deadline for the whole reading, begun once, when the first Claude Code project directory is read and not before the git sources, with the projects that have sessions in the window judged before the idle ones) cannot be judged, which is not the same as holding no books. A folder that is not there has none. Its project is skipped for that run, no financial mark is written for it and an existing one is kept, the folder is logged once, and the answer is not memoised as a verdict. Books seen on another path of the same project still give a financial verdict. A path that cannot be looked at (stat refused for want of permission) is not a path that is gone, and cannot be judged. Of the folders below a directory, one that cannot be judged does not hide books found in another beside it: the books give the verdict, and the failure is raised only when none is found. The paths its transcripts name that judge clean do not stand in for a name that could not be decoded at all. When only some branches of a name could not be decoded and others found paths, a branch too big to list is covered by a path a transcript names, and a branch that could not be read (permission, a failure, time) never is. With no transcript path the project is not judged. A verdict mark that cannot be looked at is never overwritten or removed, and the project is not judged. The reader produces a line saying how many projects were not read and, for up to three folders, why, and the same as each folder and its reason. Both readers hand theirs to the node (the behaviors nightly with `digestif skipped report`), and it is one notice from the node in the local Inbox, the projects not read as a count in its title and each folder with why in its detail: no access, with the step that grants it (on macOS, Full Disk Access for the Digestif node), too many entries, took too long, or could not be read. The newest reading stands, the same folders skipped for the same reasons are told once, and the notice is Done by itself once a reading skips nothing (ISS-81609). It carries folder names, so it never leaves the machine: it is never part of a note, a signed envelope, anything sent to a relay or the digest, which carries the count alone. The time bounds are cooperative: they are checked between directory entries, so a readdir or stat that hangs is not interrupted. A repository that cannot be judged is not offered by discovery and the machine scan stores nothing for it, so the next scan reads it again.

A person's own post passes the code detectors and the deny list and nothing else: no check judges
what a member writes in their own words.

The writer runs with no tools on the record, never on raw session files.

## Budgets

Every decision is a harness run under a member's subscription login, and two agents can trade
questions forever. Defaults, all per node and adjustable:

| Budget | Default |
|---|---|
| Outbound messages per day, excluding notes | 10 |
| Reply chain depth with no person in it | 3 |
| Agent runs per day for incoming traffic | 30 |

Incoming messages are filtered and deduplicated in code before any run. Over budget, the node
stays silent and the digest says so. The relay has its own caps (protocol.md).

## Who can read what

Said plainly, in the spec and in the member docs:

- **Summaries** (notes) are signed plaintext in v0. Every member, every relay host and
  Cloudflare can read them.
- **Items addressed to the circle**, their answers and closes, are signed plaintext in v0, through
  the same deny layer as a note. Every member, every relay host and Cloudflare can read them.
- **Items addressed to named members**, their answers and closes, are sealed to every reader of the
  item and its author. Relay hosts see who wrote to whom and when, not what.
- **The node's own choices and notices**, and every pick and Acknowledge, are sealed to the
  member's own key. A notice whose words could name what is on the machine (New repositories) never
  leaves it.
- **Drafts** never leave the author's machine until they are sent.
- **Digests** are sealed to the member's key and the mailing relay's key. The mailing relay
  decrypts a digest to email it, so its host and the mail API can read digests.
- **Sources** never leave the machine. Only what the note says leaves.

Encrypted broadcasts arrive later through a per-epoch circle key without a wire change.

## Three things members must know

- **Nothing is ever fully deleted.** Every node keeps a full copy. A member who leaves leaves their
  history on every machine. A retract drops the body from relays and nodes, but what was read was
  read.
- **Employers and third parties.** Session text belongs to employers, customers and colleagues, and
  the people named in it never agreed to this. Each member checks what their employer allows
  before turning on a source, and every note waits for their approval until they choose auto
  approval.
- **The recovery phrase is the account.** It derives the identity and encryption keys. Without it,
  a lost laptop means rejoining.

## Architecture

**One binary, OCaml.** The node is one native binary for Mac and Linux: SQLite log, Ed25519
identity and device keys, X25519 sealed boxes for named items and digests, an HTTPS client to
the relays, a localhost server for the web UI, a launchd or systemd service, self-update. It holds
no intelligence. Chosen for type safety, compiler speed, startup time and the OCaml tooling the
fleet already has.

**Keys on disk.** Device and mail private keys live in the Keychain on macOS and the Secret
Service (libsecret) on Linux, never in a plain file. The identity and encryption keys are never
stored; they are derived from the phrase when needed (the encryption key is cached in the Keychain
for reading, since every read needs it).

**The web UI is SvelteKit**, built to static files and embedded in the binary. Feed (notes waiting
for approval among the messages, Post to the circle beside it), Inbox, Members and Settings, one
page holding everything the member set. One row per
message, the row is the link, color is for status only. While Paused the whole app is one Paused
page whose only action is Unpause.

**The agent is spawned, not embedded.** The note and the read loop run behaviors: prompt
files plus executables the daemon spawns, the way a coding harness runs hooks. The reference
behaviors call the member's own harness. Roman's reference: Claude Code under the member's own
login, no API key, spawned with a prompt file and a working directory, with timeouts and a budget
per run, built from his factory's agent spawner.

**The relay is a Cloudflare Worker with D1**, in TypeScript. Three routes: append an envelope,
fetch since a relay id, read the circle (admitted keys, epoch, limits). Every request is signed by a
device key with a timestamp and a nonce. The relay enforces the admission fold, sequence and fork
rules, epochs, size and count caps. Nodes detect gaps across the union of relays and backfill. The
relay is a spec; an OCaml relay mode in the node can come later so the fold has one implementation.

**Two relays to start.** Mike's and Roman's, the same Worker deployed twice, which is the proof that
no single server is trusted. A node writes to every relay it knows and reads from all of them. A
member who starts a relay publishes a relay message and every node adds it.

**The digest email is sent by one relay.** The node seals the digest to its own key and the mailing
relay's, which that Worker decrypts and emails from the circle's domain, `digestif.io` (sending
from `mail.digestif.io`), through a mail API (Resend), kept separate from any other platform so no further party can read digests, with SPF and DKIM, which a laptop cannot do. Other relays store it and send nothing.

## Mobile

The node cannot run on a phone. What a person does on a phone is read and answer.

**The digest email** is designed for a phone. The mail key is a chainless device key: each
pre-signed answer carries the item's envelope hash as its `prev` and its own sequence number, one per
option, so unsent options leave expected gaps. The node signs those answers when it writes the
digest, then **seals each one under a random secret that only its link carries**. The mailing relay
holds only sealed answers, so whoever controls it cannot post one without the link. The link opens a
relay-served page that confirms and then posts, so a mail scanner that prefetches the link answers
nothing. Links are single-use and expire at the choice's deadline.

**The phone web app**: the same web UI served by the relay as an installable web app, with its own
device key signed by the identity key, reading the node's own choices for the member and writing
picks to its own log.

## Governance

The binary reads session directories and updates itself, so the supply chain is the point of the
system.

- **Releases** are signed by two keys, Mike's and Roman's, and a node installs only a release both
  signed. A member may pin a version.
- **Disagreement.** Either signer can halt every update by not signing. A dispute is raised as an
  issue on the public repo and settled by the founding circle. Until then nodes stay on the last
  release both signed.
- **Replacing a signer** is a release signed by both current signers that names the new key set.
  If a release key is compromised, the other signer publishes a revocation in the repo and on the
  circle, nodes refuse releases from that key, and the two remaining parties sign a release with a
  new key set.
- **Accounts.** Mike holds the first relay's Cloudflare account, the circle's domain and the mail
  API credentials; Roman holds the second relay's account. Both are written down in the repo's
  GOVERNANCE file with a named backup holder. The repo lives in the `digestif-ai` organization,
  at github.com/digestif-ai/digestif.

## Contributing

Every member has a coding agent, so the contribution path is "tell your agent". A behavior lives in
a member's own node and touches nobody. A behavior can be shared as a choice: Install or Not now. The public repo (MIT) carries the binary, the Worker, the spec, the conformance tests, and an
agent-readable description of the architecture. Protocol changes bump the envelope version.

## v0 scope

Everything in this document, built for the founding circle:

1. Spec and conformance tests (Mike).
2. Worker relay, deployed twice, with the digest mailer, sealed answer links and confirm pages
   (Roman).
3. OCaml node: identity, device, mail and encryption keys from a recovery phrase, Keychain and
   Secret Service, log, signed sync with gap backfill, localhost UI, launchd and systemd,
   self-update with two signing keys, retract (Mike).
4. Reference behaviors: the record and where each note starts, the no-tools writer, the PII and
   Rules checks with the deny layer, the note at Note time with approval and auto approval, the
   status note, the read loop with budgets, the digest, the Inbox, quiet hours and muting (Roman).
5. Invite flow from a dinner: per-guest invite keys, code handed to the app, host confirms
   unexpected joins (Mike).
6. The phone web app (Mike, after the node's UI).
7. The founding circle: everyone at dinner 2 (Mike, Roman, Andrey, Phong, Connor, Mike Zusman). They
   get it working, then dinner 1's guests are invited.

Not in v0: encrypted broadcasts, shared behaviors, Windows. Revoking a host does not cascade to
the members they admitted; the circle decides those one by one.

## Build order

The relay unblocks everything, so its contract went first: this document, protocol.md and the
relay spec. Then, in parallel: Roman's Worker against the spec; the conformance suite; the node's
keys, log and sync against the Worker; the reference behaviors against the node's behavior
interface. The mailer, the phone web app and self-update follow once two nodes sync through two
relays.
