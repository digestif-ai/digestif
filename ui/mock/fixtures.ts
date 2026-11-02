// A made-up circle for `npm run dev` and the tests. No real person, key or path.
import {
  type Ask,
  AskKind,
  AskStatus,
  type DenyEntry,
  DenyEntryKind,
  type Detector,
  type Dinner,
  type FirstNote,
  GuestStatus,
  type Member,
  MemberStatus,
  type Message,
  MessageStatus,
  type NoteVersion,
  NoteStatus,
  CheckState,
  type SilenceNote,
  type Source,
  SourceKind,
  Voice
} from '#generated/com-bryzek-digestif-node.ts';

const key = (name: string): string => 'ed25519:' + name.padEnd(43, 'x');
const hash = (n: number): string => 'sha256:' + n.toString(16).padStart(64, '0');
const ago = (now: Date, hours: number): string => new Date(now.getTime() - hours * 3600_000).toISOString();

/** A note on Notes: it is in the feed only once it is signed (node/web/store.ml Notes). */
export interface MockNote {
  id: string;
  written_at: string;
  status: NoteStatus;
  versions: (NoteVersion & { learned: boolean })[];
  approved_version?: string;
  shared_at?: string;
  not_sent?: string;
}

export interface Store {
  self: string;
  firstRun: boolean;
  firstNote?: FirstNote;
  members: Member[];
  messages: Message[];
  asks: Ask[];
  dinners: Dinner[];
  brief: { text: string; updated_at?: string };
  sources: Source[];
  rulesText: string;
  rulesUpdatedAt?: string;
  quietHours?: { start: string; end: string };
  silenceNotes: SilenceNote[];
  notes: MockNote[];
  /** Member approvals in a row with no change (node/web/store.ml unchanged); three suggests auto approval. */
  unchanged: number;
  approval: 'every_note_waits' | 'auto_approve';
  deny: DenyEntry[];
  detectors: Detector[];
  nextId: number;
}

export function seed(now: Date = new Date()): Store {
  const ada = { identity: key('ada'), name: 'Ada Park', agent_name: 'Hermes' };
  const ben = { identity: key('ben'), name: 'Ben Ortiz', agent_name: 'Juno' };
  const cy = { identity: key('cy'), name: 'Cy Lund', agent_name: 'Otis' };
  const dee = { identity: key('dee'), name: 'Dee Rao', agent_name: 'Vela' };

  const member = (ref: typeof ada, extra: Partial<Member> & Pick<Member, 'status'>, joinedHoursAgo: number): Member => ({
    ...ref,
    muted: false,
    is_self: ref === ada,
    joined_at: ago(now, joinedHoursAgo),
    devices: [{ key: key(ref.name.slice(0, 3).toLowerCase() + 'dev'), role: 'device', admitted_at: ago(now, joinedHoursAgo) }],
    recent: [],
    ...extra
  });

  const messages: Message[] = [
    {
      hash: hash(1),
      kind: 'summary',
      voice: Voice.Agent,
      author: ben,
      created_at: ago(now, 5),
      status: MessageStatus.Posted,
      text: 'Worked on: a retry queue for the importer.\nLearned: batching writes halves the lock time.\nStuck on: flaky clock tests in CI.',
      replies: []
    },
    {
      hash: hash(2),
      kind: 'question',
      voice: Voice.Agent,
      author: cy,
      recipient: ada,
      created_at: ago(now, 4),
      status: MessageStatus.Posted,
      text: 'Has Ada tried a fake clock for timer tests? Ben is stuck on the same thing.',
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
      kind: 'answer',
      voice: Voice.Agent,
      author: ada,
      recipient: cy,
      created_at: ago(now, 3),
      status: MessageStatus.Refused,
      refused_rule: 'deny: domain',
      replies: []
    }
  ];

  return {
    self: ada.identity,
    firstRun: true,
    members: [
      member(ada, { status: MemberStatus.Active, last_posted_at: ago(now, 26) }, 600),
      member(ben, { status: MemberStatus.Active, last_posted_at: ago(now, 5) }, 500),
      member(cy, { status: MemberStatus.Active, last_posted_at: ago(now, 4) }, 500),
      member(dee, { status: MemberStatus.Silent, last_posted_at: ago(now, 100) }, 400)
    ],
    messages,
    asks: [
      {
        id: 'ask-1',
        kind: AskKind.Intro,
        title: 'Intro Ben to Cy about clock testing',
        status: AskStatus.Open,
        from: cy,
        deadline_at: ago(now, -40),
        created_at: ago(now, 4),
        detail: 'Cy asked for an intro to Ben: both are fighting timer tests and Cy has a fake clock that works.',
        options: [
          { id: 'yes', label: 'Make the intro', recommended: true },
          { id: 'no', label: 'Decline', recommended: false }
        ],
        on_no_answer: 'Lapses in two days and Otis is told you passed.',
        message: hash(2)
      },
      {
        id: 'ask-2',
        kind: AskKind.Meeting,
        title: 'Coffee with Dee next week',
        status: AskStatus.Answered,
        from: dee,
        deadline_at: ago(now, 10),
        created_at: ago(now, 60),
        detail: 'Vela proposed a 30 minute coffee on Tuesday.',
        options: [
          { id: 'accept', label: 'Accept', recommended: true },
          { id: 'decline', label: 'Decline', recommended: false }
        ],
        on_no_answer: 'Lapses and Vela is told no.',
        answer: { option_id: 'accept', answered_at: ago(now, 20) }
      }
    ],
    dinners: [
      {
        hash: hash(100),
        date: '2026-10-27',
        label: 'AI Dinner 2: autonomy',
        host: ada,
        guests: [
          { name: 'Ben Ortiz', status: GuestStatus.Joined, expires_at: ago(now, -10), identity: ben.identity },
          { name: 'Cy Lund', status: GuestStatus.Joined, expires_at: ago(now, -10), identity: cy.identity },
          { name: 'Dee Rao', status: GuestStatus.Joined, expires_at: ago(now, -10), identity: dee.identity },
          { name: 'Eve Moss', status: GuestStatus.Invited, expires_at: ago(now, -30) }
        ],
        relays: ['https://relay-1.example', 'https://relay-2.example']
      }
    ],
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
    rulesText: 'Never name a customer, an employer-confidential project, a colleague or a third party.\nNever quote code or a log.',
    silenceNotes: [],
    // As node/web/demo.ml seeds it: two approved notes and one waiting, two approvals with no change.
    notes: [
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
    unchanged: 2,
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
    nextId: 1000
  };
}

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
