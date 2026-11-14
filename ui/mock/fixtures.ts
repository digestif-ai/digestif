/** The release's default Inbox prompt, as behaviors/prompts/inbox.md opens. */
export const INBOX_DEFAULT = 'Most messages need nothing from me. Read each one, and act only when it is worth my attention.';
// The read behavior's log, as GET /settings/inbox_agent/log serves it: a run that read, and one that failed.
export const INBOX_LOG = [
  '2026-11-01T09:00:00.000Z digestif: spawn behaviors/bin/read-hook',
  '2026-11-01T09:00:41.000Z the Inbox agent read 3: 1 answered, 0 answers kept for the member, 0 ideas filed, 0 practices adopted, 1 items written',
  '2026-11-01T09:00:41.000Z digestif: exited 0',
  '2026-11-01T10:00:00.000Z digestif: spawn behaviors/bin/read-hook',
  "2026-11-01T10:00:12.000Z the Inbox agent's run over 2 failed: the agent gave no answer (signed_out)",
  '2026-11-01T10:00:12.000Z digestif: exited 0'
];
// A made-up circle for `npm run dev` and the tests. No real person, key or path.
import {
  type DenyEntry,
  type InboxPractice,
  DenyEntryKind,
  type Detector,
  type Invitee,
  type Member,
  MemberStatus,
  type Message,
  MessageStatus,
  type NoteProgress,
  type NoteVersion,
  NoteStatus,
  CheckState,
  type PauseReason,
  type Source,
  SourceKind,
  Stage,
  StatusNote,
  Voice,
  type Problem,
  type PromptAdoption,
  type Suggestion,
  SuggestionStatus,
  PromptPick,
  RoundResult
} from '#generated/ai-digestif-digestif-node.ts';

const key = (name: string): string => 'ed25519:' + name.padEnd(43, 'x');
const hash = (n: number): string => 'sha256:' + n.toString(16).padStart(64, '0');
const ago = (now: Date, hours: number): string => new Date(now.getTime() - hours * 3600_000).toISOString();

/** A note: a message of the feed at its own id until it is signed (node/web/api.ml Notes.message_of). */
export interface MockNote {
  id: string;
  written_at: string;
  status: NoteStatus;
  versions: (NoteVersion & { learned: boolean })[];
  approved_version?: string;
  shared_at?: string;
  not_sent?: string;
  /** When the member dismissed it before approving it. */
  dismissed_at?: string;
  /** The first note before the run hands it over: no versions yet. */
  progress?: NoteProgress;
  /** Written in two versions for a suggestion this member judges: the suggestion, and the id of the version the suggested prompt wrote. */
  pair?: { suggestion: string; suggested: string };
}

/** A message, and the status note a summary carries when it is one (docs/protocol.md, Content bodies). */
export type MockMessage = Message & { status_note?: StatusNote };

export interface Store {
  self: string;
  firstRun: boolean;
  /** The first note's id, from the setup chat starting it until it goes out (status.first_note). */
  firstNote?: string;
  members: Member[];
  messages: MockMessage[];
  /** Invites not yet used: the Invited rows of Members. */
  invitees: Invitee[];
  brief: { text: string; updated_at?: string };
  sources: Source[];
  rulesText: string;
  rulesUpdatedAt?: string;
  quietHours?: { start: string; end: string };
  /** The problem record (docs/design.md, One way a failure is reported), open ones first. */
  problems: Problem[];
  notes: MockNote[];
  /** Member approvals in a row with no change (node/web/store.ml unchanged); five suggests auto approval. */
  unchanged: number;
  /** Write a note now was pressed: the writer runs on the node's next pass. */
  writeNow: boolean;
  approval: 'every_note_waits' | 'auto_approve';
  /** While Paused: when and why (node/web/store.ml Pause). */
  pause?: { since: string; reason: PauseReason };
  /** The last Unpause: a note's 30 days count from it when it is later. */
  unpausedAt?: string;
  /** HH:MM; the node reads 07:00 until the member saves one. */
  noteTime: string;
  /** Where the digest goes; none until the member saves one, as in the demo node. */
  digestEmail?: string;
  /** The local hour after which the digest is written; the node reads 7 until one is saved. */
  digestHour: number;
  /** The agent Settings saved; none until one passes the check, as in the demo node. */
  agent?: { name: string; path: string };
  /** The newest agent check Save started: it reads checking until endsAt, then its result. */
  agentCheck?: { name: string; path: string; endsAt: number; message?: string | undefined };
  learnings: { text: string; updated_at?: string };
  /** The member's Inbox prompt, the default until they save their own (ISS-52611). */
  inboxPrompt: { text: string; updated_at?: string };
  /** Whether the agent adopts practices from the circle on its own, and those it adopted (ISS-80159). */
  adoptPractices: boolean;
  practices: InboxPractice[];
  deny: DenyEntry[];
  detectors: Detector[];
  /** Every suggestion to change the nightly note prompt, oldest first (ISS-51009). */
  suggestions: Suggestion[];
  /** The circle's live prompt, once a suggestion is adopted; absent while the release's stands. */
  livePrompt?: { text: string; adoption: PromptAdoption };
  nextId: number;
}

export function seed(now: Date = new Date()): Store {
  const ada = { identity: key('ada'), name: 'Ada Park', agent_name: 'Hermes' };
  const ben = { identity: key('ben'), name: 'Ben Ortiz', agent_name: 'Juno' };
  const cy = { identity: key('cy'), name: 'Cy Lund', agent_name: 'Otis' };
  const dee = { identity: key('dee'), name: 'Dee Rao', agent_name: 'Vela' };
  const fay = { identity: key('fay'), name: 'Fay Kim', agent_name: 'Pax' };

  const member = (ref: typeof ada, extra: Partial<Member> & Pick<Member, 'status' | 'stage'>, joinedHoursAgo: number): Member => ({
    ...ref,
    muted: false,
    is_self: ref === ada,
    joined_at: ago(now, joinedHoursAgo),
    devices: [{ key: key(ref.name.slice(0, 3).toLowerCase() + 'dev'), role: 'device', admitted_at: ago(now, joinedHoursAgo) }],
    recent: [],
    ...extra
  });

  const messages: MockMessage[] = [
    {
      hash: hash(1),
      kind: 'summary',
      voice: Voice.Agent,
      author: ben,
      created_at: ago(now, 5),
      status: MessageStatus.Posted,
      text: 'Worked on: a retry queue for the importer.\nLearned: batching writes halves the lock time.\nStuck on: flaky clock tests in CI.',
      reviewed_at: ago(now, 4),
      review: 'Filed the flaky clock tests as digestif-ai/digestif#318, as your Inbox prompt says for work on Digestif.',
      replies: []
    },
    {
      hash: hash(2),
      kind: 'summary',
      voice: Voice.Agent,
      author: cy,
      created_at: ago(now, 4),
      status: MessageStatus.Posted,
      text: 'Has anyone tried a fake clock for timer tests? Ben is stuck on the same thing.',
      replies: []
    },
    {
      hash: hash(3),
      kind: 'summary',
      voice: Voice.Person,
      author: dee,
      created_at: ago(now, 30),
      status: MessageStatus.Posted,
      text: 'Anyone going to the next dinner? I can host in November.',
      replies: []
    },
    {
      hash: hash(5),
      kind: 'summary',
      voice: Voice.Agent,
      author: ada,
      created_at: ago(now, 3),
      status: MessageStatus.Refused,
      refused_rule: 'deny: domain',
      replies: []
    },
    // Ben's note waited a day for his approval before it went out: one Feed thread (ISS-85464).
    {
      hash: hash(8),
      kind: 'summary',
      voice: Voice.Agent,
      author: ben,
      created_at: ago(now, 29),
      status: MessageStatus.Posted,
      status_note: StatusNote.WaitingForApproval,
      replies: []
    },
    // Cy's machine could not run today, and Dee pressed Pause (as in node/web/demo.ml).
    {
      hash: hash(6),
      kind: 'summary',
      voice: Voice.Agent,
      author: cy,
      created_at: ago(now, 8),
      status: MessageStatus.Posted,
      status_note: StatusNote.CouldNotRun,
      replies: []
    },
    {
      hash: hash(7),
      kind: 'summary',
      voice: Voice.Agent,
      author: dee,
      created_at: ago(now, 90),
      status: MessageStatus.Posted,
      status_note: StatusNote.Paused,
      replies: []
    }
  ];

  return {
    self: ada.identity,
    firstRun: true,
    members: [
      member(ada, { status: MemberStatus.Active, stage: Stage.Active, last_note_at: ago(now, 26) }, 600),
      member(ben, { status: MemberStatus.Active, stage: Stage.Active, last_note_at: ago(now, 5) }, 500),
      member(
        cy,
        { status: MemberStatus.Active, stage: Stage.Active, last_note_at: ago(now, 8), last_status_note: StatusNote.CouldNotRun },
        500
      ),
      member(
        dee,
        { status: MemberStatus.Active, stage: Stage.Paused, last_note_at: ago(now, 90), last_status_note: StatusNote.Paused },
        400
      ),
      member(fay, { status: MemberStatus.Active, stage: Stage.Onboarding }, 40)
    ],
    messages,
    invitees: [{ name: 'Eve Moss', expires_at: ago(now, -30), invited_by: ada }],
    brief: { text: '' },
    sources: [
      {
        id: 'claude-code',
        kind: SourceKind.ClaudeCode,
        label: 'Claude Code sessions',
        paths: ['~/code/side-project'],
        yields: ['Session titles', 'Your own prompts', 'File paths under the listed directories'],
        selected: false
      },
      {
        id: 'git',
        kind: SourceKind.Git,
        label: 'Git repositories',
        paths: ['~/code/side-project', '~/code/dotfiles'],
        yields: ['Commit subjects', 'Diff stats of the listed repositories'],
        selected: false
      }
    ],
    noteTime: '07:00',
    digestHour: 7,
    learnings: { text: '' },
    inboxPrompt: { text: INBOX_DEFAULT },
    adoptPractices: false,
    practices: [
      {
        id: 'practice-1',
        text: 'Answer a scheduling question with two times that suit me.',
        author: ben,
        about: 'sha256:' + 'b'.repeat(64),
        adopted_at: '2026-11-10T15:00:00Z'
      }
    ],
    rulesText: 'Never name a customer, an employer-confidential project, a colleague or a third party.\nNever quote code or a log.',
    problems: [],
    // As node/web/demo.ml seeds it: four approved notes and one waiting, four approvals with no change.
    notes: [
      note(now, 'n4', 96, NoteStatus.Approved, 'Worked on: the release checklist.\nStuck on: nothing.'),
      note(now, 'n5', 72, NoteStatus.Approved, "Worked on: the relay's retry budget.\nStuck on: nothing."),
      note(now, 'n1', 48, NoteStatus.Approved, 'Worked on: the importer retry queue.\nLearned: retries need a cap.\nStuck on: nothing.'),
      note(
        now,
        'n2',
        24,
        NoteStatus.Approved,
        'Worked on: batching writes in the loader.\nLearned: batching halves the lock time.\nStuck on: nothing.'
      ),
      note(
        now,
        'n3',
        2,
        NoteStatus.Waiting,
        'Worked on: the local web UI.\nLearned: static builds embed cleanly.\nStuck on: nothing tonight.'
      )
    ],
    unchanged: 4,
    writeNow: false,
    approval: 'every_note_waits',
    deny: [{ id: 'deny-1', kind: DenyEntryKind.Domain, value: 'internal.example.com', created_at: ago(now, 300), trips: 1 }],
    detectors: [
      { name: 'Key and token shapes', description: 'API keys, bearer tokens, cloud credentials' },
      { name: 'Private keys', description: 'PEM blocks and raw key material' },
      { name: 'Connection strings', description: 'Database and service URLs with credentials' },
      { name: 'Payment card numbers', description: 'Luhn-checked card numbers' },
      { name: 'Bank account numbers', description: 'IBANs with their checksum, US routing and account pairs' },
      { name: 'Crypto wallets', description: 'Wallet addresses and keys, checksum-verified' },
      { name: 'Recovery phrases', description: 'BIP39 words with a valid checksum' },
      { name: 'High-entropy strings', description: 'Long random-looking values' }
    ],
    // Ben's suggestion was adopted on its second round and is the circle's prompt; Ada's judges now.
    suggestions: [
      {
        hash: hash(901),
        author: ben,
        created_at: ago(now, 200),
        change: 'Lead with what was learned',
        text: LIVE_PROMPT,
        prompt_id: 'sha256:' + 'b'.repeat(64),
        judges: [ben, ada],
        status: SuggestionStatus.Adopted,
        judge: true,
        running: false,
        rounds: [
          {
            number: 1,
            picks: [
              { judge: ben, pick: PromptPick.Suggested, at: ago(now, 180) },
              { judge: ada, pick: PromptPick.Current, at: ago(now, 178) }
            ],
            result: RoundResult.Split
          },
          {
            number: 2,
            picks: [
              { judge: ben, pick: PromptPick.Suggested, at: ago(now, 156) },
              { judge: ada, pick: PromptPick.Suggested, at: ago(now, 154) }
            ],
            result: RoundResult.Adopted
          }
        ],
        decided_at: ago(now, 154),
        live: true,
        can_withdraw: false,
        pull_request_owed: false
      },
      {
        hash: hash(902),
        author: ada,
        created_at: ago(now, 30),
        change: 'Keep Stuck on to one line',
        text: LIVE_PROMPT + '\nKeep Stuck on to one line.',
        prompt_id: 'sha256:' + 'c'.repeat(64),
        judges: [ada, cy],
        status: SuggestionStatus.Judging,
        judge: true,
        running: true,
        rounds: [{ number: 1, picks: [{ judge: cy, pick: PromptPick.Suggested, at: ago(now, 8) }] }],
        live: false,
        can_withdraw: true,
        pull_request_owed: false
      }
    ],
    livePrompt: {
      text: LIVE_PROMPT,
      adoption: { suggestion: hash(901), change: 'Lead with what was learned', author: ben, at: ago(now, 154) }
    },
    nextId: 1000
  };
}

const LIVE_PROMPT = "You write one person's nightly note from the record of their day.\nLead with what was learned.\n{{always_on_rules}}";

const passed = { pii: CheckState.Passed, rules: CheckState.Passed };

function note(now: Date, id: string, hoursAgo: number, status: NoteStatus, text: string): MockNote {
  const at = ago(now, hoursAgo);
  const version = { id: id + '-v1', number: 1, voice: Voice.Agent, created_at: at, checks: passed, text, removed: false, learned: true };
  return {
    id,
    written_at: at,
    status,
    versions: [version],
    ...(status === NoteStatus.Waiting ? {} : { approved_version: version.id, shared_at: ago(now, hoursAgo - 1) })
  };
}
