// The Inbox's items for the mock node (docs/protocol.md, Items; DES-51007): a made-up Inbox holding
// every kind the pages show, and the rules of the node API's item operations, loosely enough to drive
// every screen. Each reader's status is the member's own, so the mock keeps one reader: the member.
import {
  ItemAgentAskStatus,
  ItemDone,
  ItemKind,
  ItemState,
  ItemStatus,
  ItemSubject,
  ItemWaitingOn,
  ItemWaitingAct,
  Voice,
  type Item,
  type ItemSummary,
  type ItemWaiting,
  type MemberRef,
  type NodeError
} from '#generated/ai-digestif-digestif-node.ts';
import { itemThreadKey } from '#lib/threads.ts';

interface MockResponse {
  status: number;
  body?: unknown;
}

type Route = [string, string, (p: string[], body: unknown, q: URLSearchParams) => MockResponse];

const err = (status: number, code: string, message: string, field?: string): MockResponse => ({
  status,
  body: [{ code, message, ...(field === undefined ? {} : { field: field }) } satisfies NodeError]
});
const notFound = (): MockResponse => err(404, 'not_found', 'Not found.');
const ok = (body: unknown, status = 200): MockResponse => ({ status, body });

function field(body: unknown, name: string): unknown {
  return body === null || typeof body !== 'object' ? undefined : (body as Record<string, unknown>)[name];
}
const text = (body: unknown, name: string): string | undefined => {
  const v = field(body, name);
  return typeof v === 'string' ? v : undefined;
};

/** What the mock node reads from the rest of its circle. */
export interface ItemsCircle {
  self(): MemberRef;
  /** Every member still in the circle. */
  members(): MemberRef[];
  /** Repositories waiting for the member to decide: the node's New repositories notice. */
  undecided(): number;
  /** Whether an agent is connected on Setup, so Ask your agent has somewhere to go. */
  agentConnected(): boolean;
  /** The deny layer: the rule a text trips, if any. */
  trip(text: string): string | undefined;
  /** A work notice's reply to the note it is about, when that is another member's note (ISS-83154). */
  reply(about: string): Pick<Item, 'reply_to' | 'agent_answer' | 'draft_reply'> | undefined;
}

export function summaryOf(x: Item): ItemSummary {
  const {
    id,
    kind,
    subject,
    voice,
    author,
    to,
    title,
    status,
    closed,
    deadline_at,
    created_at,
    about,
    link,
    reviewed_at,
    done,
    archived_at,
    waiting
  } = x;
  return {
    id,
    kind,
    voice,
    author,
    to,
    title,
    status,
    closed,
    created_at,
    ...(subject === undefined ? {} : { subject }),
    ...(deadline_at === undefined ? {} : { deadline_at }),
    ...(about === undefined ? {} : { about }),
    ...(link === undefined ? {} : { link }),
    ...(done === undefined ? {} : { done }),
    ...(archived_at === undefined ? {} : { archived_at }),
    ...(waiting === undefined ? {} : { waiting }),
    ...(reviewed_at === undefined ? {} : { reviewed_at })
  };
}

const RANK: Record<ItemStatus, number> = { draft: 0, new: 0, read: 1, done: 1 };

export class MockItems {
  items: Item[];
  private nextId = 0;

  constructor(
    private readonly circle: ItemsCircle,
    now: Date = new Date()
  ) {
    this.items = seedItems(circle, now);
  }

  /** The Inbox count: one for each bold row, a thread of the member's Inbox holding a Draft or New item (DIG-179). */
  count(): number {
    const unread = this.inbox().filter((x) => x.status === ItemStatus.Draft || x.status === ItemStatus.New);
    return new Set(unread.map(itemThreadKey)).size;
  }

  /**
   * The Inbox's items (ISS-64736): what the member or their agent sent to anyone but the member stays
   * out until someone else answers or picks it, and what they archived is out (ISS-88476).
   */
  private inbox(): Item[] {
    return this.all().filter((x) => x.archived_at === undefined && (!this.mineSent(x) || this.actedOn(x)));
  }

  /** What the member or their agent sent to anyone but the member. */
  private mineSent(x: Item): boolean {
    const me = this.circle.self().identity;
    const toMeAlone = !x.to.circle && x.to.members.length === 1 && x.to.members[0]?.identity === me;
    return x.status !== ItemStatus.Draft && x.voice !== Voice.Node && x.author.identity === me && !toMeAlone;
  }

  private actedOn(x: Item): boolean {
    const me = this.circle.self().identity;
    return x.answers.some((a) => a.author.identity !== me) || x.picks.some((p) => p.member.identity !== me);
  }

  /** Whom the item waits on, as the node's Inbox.waiting says (spec item_waiting). */
  private waitingOf(x: Item): ItemWaiting | undefined {
    const me = this.circle.self().identity;
    const you = (act: ItemWaitingAct): ItemWaiting => ({ on: ItemWaitingOn.You, act });
    if (x.status === ItemStatus.Draft) return you(ItemWaitingAct.Send);
    if (x.closed) return undefined;
    if (x.voice === Voice.Node || x.author.identity !== me) {
      if (x.done !== undefined) return undefined;
      if (x.kind === ItemKind.Question) return you(ItemWaitingAct.Answer);
      if (x.kind === ItemKind.Choice) return you(ItemWaitingAct.Pick);
      return x.subject === ItemSubject.Approval ? you(ItemWaitingAct.Approve) : undefined;
    }
    if (x.kind !== ItemKind.Question && x.kind !== ItemKind.Choice) return undefined;
    // DIG-535: acting is an answer on a question or a pick on a choice; a reply never acts.
    const acted = (x.kind === ItemKind.Question ? x.answers.map((a) => a.author.identity) : x.picks.map((p) => p.member.identity)).filter(
      (i) => i !== me
    );
    if (x.to.circle) return acted.length === 0 ? { on: ItemWaitingOn.Others, circle: true, members: [] } : undefined;
    const left = x.to.members.filter((m) => m.identity !== me && !acted.includes(m.identity));
    return left.length === 0 ? undefined : { on: ItemWaitingOn.Others, circle: false, members: left };
  }

  /** The item as the node gives it, with whom it waits on. */
  private view(x: Item): Item {
    const waiting = this.waitingOf(x);
    const { waiting: _old, ...rest } = x;
    return waiting === undefined ? rest : { ...rest, waiting };
  }

  /** In a view of the Inbox, as the node's Store.Items.state_condition says (spec item_state). */
  private inState(x: Item, st: ItemState): boolean {
    const w = this.waitingOf(x);
    if (st === ItemState.Archived || st === ItemState.Done) return x.archived_at !== undefined;
    if (x.archived_at !== undefined) return false;
    if (st === ItemState.Others) return w?.on === ItemWaitingOn.Others;
    return w?.on === ItemWaitingOn.You && this.inbox().includes(x);
  }

  /** The Inbox items whose title or detail holds every word [has] is handed, the newest first, each with the text searched (GET /search). */
  search(has: (...fields: string[]) => boolean, limit: number): { summary: ItemSummary; text: string }[] {
    return this.inbox()
      .filter((x) => has(x.title, x.detail))
      .sort((x, y) => y.created_at.localeCompare(x.created_at))
      .slice(0, limit)
      .map((x) => ({ summary: summaryOf(this.view(x)), text: x.title + '\n' + x.detail }));
  }

  routes(): Route[] {
    const found = (id: string | undefined, run: (x: Item) => MockResponse): MockResponse => {
      const x = this.all().find((i) => i.id === id);
      return x === undefined ? notFound() : run(x);
    };
    return [
      ['GET', 'items', (_p, _b, q) => this.list(q)],
      ['GET', 'items/threads/:', ([key]) => ok(this.thread(key ?? ''))],
      ['POST', 'items', (_p, b) => this.create(b)],
      ['GET', 'items/:', ([id]) => found(id, (x) => ok(this.view(this.withReply(x))))],
      ['PUT', 'items/:', ([id], b) => found(id, (x) => this.edit(x, b))],
      ['DELETE', 'items/:', ([id]) => found(id, (x) => this.discard(x))],
      ['POST', 'items/:/send', ([id]) => found(id, (x) => this.send(x))],
      ['POST', 'items/:/read', ([id]) => found(id, (x) => this.read(x))],
      ['POST', 'items/:/unread', ([id]) => found(id, (x) => this.unread(x))],
      ['POST', 'items/:/archive', ([id]) => found(id, (x) => this.archive(x, true))],
      ['DELETE', 'items/:/archive', ([id]) => found(id, (x) => this.archive(x, false))],
      ['POST', 'items/:/answers', ([id], b) => found(id, (x) => this.answer(x, b))],
      ['POST', 'items/:/picks', ([id], b) => found(id, (x) => this.pick(x, b))],
      ['POST', 'items/:/acknowledge', ([id]) => found(id, (x) => this.acknowledge(x))],
      ['POST', 'items/:/ask-agent', ([id]) => found(id, (x) => this.askAgent(x))],
      ['POST', 'items/:/not_for_me', ([id]) => found(id, (x) => this.notForMe(x))],
      ['PUT', 'items/:/close', ([id], b) => found(id, (x) => this.close(x, b))]
    ];
  }

  /** The stored items, and the node's own New repositories notice while any repository waits. */
  private all(): Item[] {
    const connected = this.circle.agentConnected();
    for (const x of this.items) {
      if (x.voice === Voice.Node && x.path !== undefined && x.done === undefined) x.agent_connected = connected;
    }
    const n = this.circle.undecided();
    const stored = this.items.filter((x) => x.subject !== ItemSubject.Repositories);
    const held = this.items.find((x) => x.subject === ItemSubject.Repositories);
    if (n === 0 || held === undefined) return stored;
    held.title = n === 1 ? 'A new repository waits on your machine' : String(n) + ' new repositories wait on your machine';
    return [held, ...stored];
  }

  /** One Inbox thread, oldest first: every item the member has (the Inbox, Waiting on others, the Archive) under [key]. */
  private thread(key: string): ItemSummary[] {
    const theirs = (x: Item): boolean => this.inbox().includes(x) || this.inState(x, ItemState.Others) || x.archived_at !== undefined;
    return this.all()
      .filter((x) => itemThreadKey(x) === key && theirs(x))
      .sort((x, y) => x.created_at.localeCompare(y.created_at))
      .map((x) => summaryOf(this.view(x)));
  }

  private list(q: URLSearchParams): MockResponse {
    const statuses = q.getAll('status').filter((s) => s !== '');
    if (statuses.some((s) => !Object.values(ItemStatus).includes(s as ItemStatus))) return err(422, 'status', 'Not a status.', 'status');
    const many = <T extends string>(name: string, values: T[]): T[] | MockResponse => {
      const given = q.getAll(name).filter((s) => s !== '');
      return given.every((s) => values.includes(s as T)) ? (given as T[]) : err(422, name, 'Not a ' + name + '.', name);
    };
    const states = many('state', Object.values(ItemState));
    const kinds = many('kind', Object.values(ItemKind));
    const subjects = many('subject', Object.values(ItemSubject));
    const voices = many('voice', Object.values(Voice));
    if (!Array.isArray(states)) return states;
    if (!Array.isArray(kinds)) return kinds;
    if (!Array.isArray(subjects)) return subjects;
    if (!Array.isArray(voices)) return voices;
    const named = (x: Item): boolean =>
      ((kinds.length === 0 && subjects.length === 0) ||
        (x.subject === undefined ? kinds.includes(x.kind) : subjects.includes(x.subject))) &&
      (voices.length === 0 || voices.includes(x.voice));
    const inState = (x: Item): boolean => states.some((st) => this.inState(x, st));
    const rows = (states.length === 0 ? this.inbox() : this.all().filter(inState))
      .filter((x) => (statuses.length === 0 || statuses.includes(x.status)) && named(x))
      .sort((x, y) => RANK[x.status] - RANK[y.status] || y.created_at.localeCompare(x.created_at))
      .map((x) => summaryOf(this.view(x)));
    const limit = Number(q.get('limit') ?? '100');
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) return err(422, 'limit', 'Not a valid limit.', 'limit');
    const cursor = q.get('cursor');
    let start = 0;
    if (cursor !== null && cursor !== '') {
      const i = rows.findIndex((r) => r.id === cursor);
      if (i < 0) return err(422, 'cursor', 'Not a valid cursor.', 'cursor');
      start = i + 1;
    }
    return ok(rows.slice(start, start + limit));
  }

  /** The members a form names, or the error that refuses it. */
  private named(body: unknown): MemberRef[] | MockResponse {
    const ids = field(body, 'members');
    if (ids === undefined) return [];
    if (!Array.isArray(ids) || !ids.every((x) => typeof x === 'string')) return err(422, 'members', 'Not a list of members.', 'members');
    const members = this.circle.members();
    const refs: MemberRef[] = [];
    for (const id of ids) {
      const m = members.find((x) => x.identity === id);
      if (m === undefined) return err(422, 'members', 'Not a member of the circle.', 'members');
      if (!refs.some((r) => r.identity === id)) refs.push(m);
    }
    return refs;
  }

  private create(body: unknown): MockResponse {
    const kind = text(body, 'kind') as ItemKind | undefined;
    if (kind === undefined || !Object.values(ItemKind).includes(kind)) return err(422, 'kind', 'Not a kind.', 'kind');
    const subject = text(body, 'subject') as ItemSubject | undefined;
    if (subject !== undefined && subject !== ItemSubject.Intro && subject !== ItemSubject.Suggestion)
      return err(422, 'subject', 'A member writes a question, a notice, an intro or a prompt suggestion.', 'subject');
    const title = (text(body, 'title') ?? '').trim();
    if (title === '') return err(422, 'empty', 'Write a title.', 'title');
    const detail = text(body, 'detail') ?? '';
    const about = text(body, 'about');
    const circle = field(body, 'circle') === true;
    const members = this.named(body);
    if (!Array.isArray(members)) return members;
    if (!circle && members.length === 0) return err(422, 'members', 'Name at least one member, or send it to the circle.', 'members');
    if (subject === ItemSubject.Intro && members.length !== 2)
      return err(422, 'members', 'An intro names the two people it introduces.', 'members');
    const self = this.circle.self();
    this.nextId += 1;
    const x: Item = {
      id: 'itm-new-' + String(this.nextId),
      kind,
      ...(subject === undefined ? {} : { subject }),
      voice: Voice.Person,
      author: self,
      to: { circle, members: circle ? [] : members },
      title,
      detail,
      ...(about === undefined ? {} : { about }),
      status: ItemStatus.Draft,
      closed: false,
      created_at: new Date().toISOString(),
      local: false,
      options: [],
      answers: [],
      picks: [],
      closes: []
    };
    if (field(body, 'send') === true) {
      const refused = this.deliver(x);
      if (refused !== undefined) return refused;
    }
    this.items.push(x);
    return ok(x, 201);
  }

  /** Sending: through the deny layer, then the author's item is Read for them and New for the rest. */
  private deliver(x: Item): MockResponse | undefined {
    const rule = this.circle.trip(x.title + '\n' + x.detail);
    if (rule !== undefined) return err(422, 'refused', 'Not sent: refused by ' + rule + '.');
    const now = new Date().toISOString();
    x.status = ItemStatus.Read;
    x.sent_at = now;
    x.read_at = now;
    x.hash = 'sha256:' + x.id.replace(/[^0-9a-z]/g, '').padStart(64, '0');
    return undefined;
  }

  private edit(x: Item, body: unknown): MockResponse {
    if (x.status !== ItemStatus.Draft) return err(422, 'not_draft', 'Only a draft is edited.');
    const title = (text(body, 'title') ?? '').trim();
    if (title === '') return err(422, 'empty', 'Write a title.', 'title');
    const members = this.named(body);
    if (!Array.isArray(members)) return members;
    // The agent's words are kept the first time its member changes them.
    if (x.voice === Voice.Agent && x.drafted === undefined) x.drafted = { title: x.title, detail: x.detail };
    x.title = title;
    x.detail = text(body, 'detail') ?? '';
    const circle = field(body, 'circle');
    if (circle === true) x.to = { circle: true, members: [] };
    else if (members.length > 0) x.to = { circle: false, members };
    return ok(x);
  }

  private discard(x: Item): MockResponse {
    if (x.status !== ItemStatus.Draft) return err(422, 'not_draft', 'Only a draft is discarded.');
    this.items = this.items.filter((i) => i !== x);
    return { status: 204 };
  }

  private send(x: Item): MockResponse {
    if (x.status !== ItemStatus.Draft) return err(422, 'not_draft', 'Already sent.');
    return this.deliver(x) ?? ok(x, 201);
  }

  private read(x: Item): MockResponse {
    if (x.status === ItemStatus.New) {
      x.status = ItemStatus.Read;
      x.read_at ??= new Date().toISOString();
    }
    return ok(x);
  }

  private unread(x: Item): MockResponse {
    if (x.status === ItemStatus.Draft) return err(422, 'not_sent', 'This item is a draft.');
    x.status = ItemStatus.New;
    return ok(x);
  }

  private archive(x: Item, archived: boolean): MockResponse {
    if (archived && x.status === ItemStatus.Draft) return err(422, 'not_sent', 'This item is a draft.');
    if (archived) x.archived_at ??= new Date().toISOString();
    else delete x.archived_at;
    return ok(x);
  }

  /** An answer to a question, or a reply to a notice or a choice, which joins the item as an answer does (ISS-88476). */
  private answer(x: Item, body: unknown): MockResponse {
    if (x.voice === Voice.Node || x.local) return err(422, 'not_answerable', "Your node's own items take no reply.");
    const me = this.circle.self().identity;
    const toSelf = x.author.identity === me && !x.to.circle && x.to.members.every((m) => m.identity === me);
    if (toSelf) return err(422, 'to_self', 'Only you read this item, so a reply would reach no one.');
    // DIG-538: only a question is refused once closed. A reply on a closed notice or choice reopens nothing.
    if (x.kind === ItemKind.Question && x.closed) return err(422, 'closed', 'This question is closed.');
    const words = (text(body, 'text') ?? '').trim();
    if (words === '') return err(422, 'empty', 'Write an answer.', 'text');
    const rule = this.circle.trip(words);
    if (rule !== undefined) return err(422, 'refused', 'Not sent: refused by ' + rule + '.', 'text');
    this.nextId += 1;
    x.answers.push({
      hash: 'sha256:' + this.nextId.toString(16).padStart(64, 'a'),
      author: this.circle.self(),
      voice: Voice.Person,
      text: words,
      created_at: new Date().toISOString()
    });
    if (x.kind === ItemKind.Question && x.author.identity !== this.circle.self().identity) {
      x.status = ItemStatus.Read;
      x.done = ItemDone.Answered;
    }
    return ok(x, 201);
  }

  private pick(x: Item, body: unknown): MockResponse {
    if (x.kind !== ItemKind.Choice) return err(422, 'not_choice', 'Only a choice takes a pick.');
    if (x.closed) return err(422, 'closed', 'This choice is closed.');
    const self = this.circle.self();
    if (x.picks.some((p) => p.member.identity === self.identity)) return err(422, 'picked', 'You already picked.');
    const option = text(body, 'option_id');
    if (option === undefined || !x.options.some((o) => o.id === option)) return err(422, 'unknown_option', 'No such option.', 'option_id');
    const now = new Date().toISOString();
    x.picks.push({ member: self, option_id: option, picked_at: now });
    // A choice closes on its first pick.
    x.closed = true;
    x.close = { closed: true, voice: Voice.Person, at: now };
    x.closes = [x.close, ...x.closes];
    x.status = ItemStatus.Read;
    x.done = ItemDone.Picked;
    return ok(x, 201);
  }

  private acknowledge(x: Item): MockResponse {
    if (x.kind !== ItemKind.Notice) return err(422, 'not_notice', 'Only a notice is acknowledged.');
    x.status = ItemStatus.Read;
    x.done = ItemDone.Acknowledged;
    x.archived_at ??= new Date().toISOString();
    return ok(x);
  }

  /** A work notice about another member's note carries the reply to it, as the node's does. */
  private withReply(x: Item): Item {
    if (x.kind !== ItemKind.Notice || x.subject !== ItemSubject.Work || x.about === undefined) return x;
    const r = this.circle.reply(x.about);
    return r === undefined ? x : { ...x, ...r };
  }

  private askAgent(x: Item): MockResponse {
    if (!this.circle.agentConnected()) return err(422, 'no_agent', 'Connect an agent on Setup first. Ask your agent goes to it.');
    if (x.path === undefined || x.voice !== Voice.Node || x.done !== undefined)
      return err(422, 'not_askable', 'Only an open notice from your node with a page can be asked about.');
    if (x.agent_ask?.status === ItemAgentAskStatus.Asked) return err(422, 'asking', 'Your agent is already working on this.');
    const asked = { status: ItemAgentAskStatus.Asked, at: new Date().toISOString() };
    x.agent_ask = asked;
    // The agent answers a moment later, as the node's does when its run ends.
    setTimeout(() => {
      x.agent_ask = {
        status: ItemAgentAskStatus.Answered,
        at: new Date().toISOString(),
        reply: 'I opened the page. Nothing needed a change.'
      };
    }, 1500);
    return ok(asked, 202);
  }

  private notForMe(x: Item): MockResponse {
    if (x.kind !== ItemKind.Question) return err(422, 'not_question', 'Only a question is set aside.');
    if (x.author.identity === this.circle.self().identity) return err(422, 'mine', 'You asked this question.');
    x.status = ItemStatus.Read;
    x.done = ItemDone.NotForMe;
    x.archived_at ??= new Date().toISOString();
    return ok(x);
  }

  private close(x: Item, body: unknown): MockResponse {
    if (x.author.identity !== this.circle.self().identity || x.status === ItemStatus.Draft)
      return err(422, 'not_yours', 'Only its author closes an item they sent.');
    const answer = text(body, 'answer');
    if (answer !== undefined && !x.answers.some((a) => a.hash === answer))
      return err(422, 'unknown_answer', 'Not one of its answers.', 'answer');
    const closed = field(body, 'closed') === true;
    const c = { closed, voice: Voice.Person, at: new Date().toISOString(), ...(closed && answer !== undefined ? { answer } : {}) };
    x.closes = [c, ...x.closes];
    if (closed) {
      x.close = c;
      x.closed = true;
      x.done = ItemDone.Closed;
    } else {
      delete x.close;
      delete x.done;
      x.closed = false;
    }
    return ok(x);
  }
}

/** The made-up Inbox: one of each thing the pages show (design/digestif/inbox.html). */
function seedItems(circle: ItemsCircle, now: Date): Item[] {
  const ago = (hours: number): string => new Date(now.getTime() - hours * 3600_000).toISOString();
  const me = circle.self();
  const find = (first: string): MemberRef => {
    const m = circle.members().find((x) => x.name.startsWith(first));
    if (m === undefined) throw new Error('fixture has no ' + first);
    return m;
  };
  const ben = find('Ben');
  const cy = find('Cy');
  const dee = find('Dee');
  const answer = (n: number, author: MemberRef, voice: Voice, words: string, hours: number): Item['answers'][number] => ({
    hash: 'sha256:' + n.toString(16).padStart(64, 'b'),
    author,
    voice,
    text: words,
    created_at: ago(hours)
  });
  const base = { local: false, options: [], answers: [], picks: [], closes: [], closed: false };
  const agentClose = { closed: true, voice: Voice.Agent, at: ago(60), answer: 'sha256:' + (11).toString(16).padStart(64, 'b') };
  return [
    {
      ...base,
      id: 'itm-question',
      kind: ItemKind.Question,
      subject: ItemSubject.NoteQuestion,
      voice: Voice.Agent,
      author: ben,
      to: { circle: true, members: [] },
      title: 'How do you keep eval sets from leaking into fine-tune data?',
      detail:
        'We split by repository, but two customers share a data vendor and the same rows show up on both sides. Is anyone deduplicating by embedding distance before the split?',
      status: ItemStatus.New,
      created_at: ago(2),
      sent_at: ago(2),
      reviewed_at: ago(1),
      hash: 'sha256:' + (1001).toString(16).padStart(64, '0'),
      about: 'sha256:' + (1).toString(16).padStart(64, '0'),
      review:
        'Drafted an answer from your Oct 28 note. It names a repository, which your Rules keep out of the circle, so it waits for you.',
      answers: [
        answer(1, cy, Voice.Person, 'We do MinHash over 5-gram shingles at 0.8 Jaccard first, then cosine on the survivors.', 1),
        answer(2, dee, Voice.Agent, 'Dee wrote about this in her Oct 30 note: her team holds out a whole vendor rather than rows.', 0.6)
      ],
      // A reply to Ben's note (DIG-837): a candidate answer, shown beside the answers, never one of them.
      note_replies: [
        {
          hash: 'sha256:' + (21).toString(16).padStart(64, 'b'),
          author: dee,
          voice: Voice.Person,
          text: 'Holding out a whole vendor worked for us too.',
          created_at: ago(0.4),
          reply_to: 'sha256:' + (1).toString(16).padStart(64, '0')
        }
      ]
    },
    {
      ...base,
      id: 'itm-repositories',
      kind: ItemKind.Notice,
      subject: ItemSubject.Repositories,
      voice: Voice.Node,
      author: me,
      to: { circle: false, members: [me] },
      title: 'New repositories wait on your machine',
      detail: 'Your agent found repositories it has not been told to read or skip. Until you choose, it reads none of them.',
      status: ItemStatus.New,
      created_at: ago(3),
      local: true,
      path: '/settings/repositories/edit?status=undecided'
    },
    {
      ...base,
      id: 'itm-send-invite',
      kind: ItemKind.Notice,
      subject: ItemSubject.SendInvite,
      voice: Voice.Node,
      author: me,
      to: { circle: false, members: [me] },
      title: "Send Priya Raman's invite.",
      detail:
        'Send the email below to priya@raman.dev from your own address, then mark it sent. The invite works until Tuesday, November 17 at 10:00 AM ET.',
      status: ItemStatus.New,
      created_at: ago(1),
      local: true,
      invite_email: {
        to: 'Priya Raman <priya@raman.dev>',
        subject: 'Join the AI Dinner 2 circle on Digestif',
        text: 'Hi Priya,\n\nCome and see.\n\nDigestif is a nightly note between a few of us, written by each person’s own agent.\n\ncurl -fsSL https://digestif.io/install.sh | sh -s -- --join digestif:AbC123\n\nThis invite is yours alone and works once, until Tuesday, November 17 at 10:00 AM ET.\n\nMike',
        mailto: 'mailto:Priya%20Raman%20%3Cpriya%40raman.dev%3E?subject=Join%20the%20AI%20Dinner%202%20circle%20on%20Digestif'
      }
    },
    {
      ...base,
      id: 'itm-intro',
      kind: ItemKind.Notice,
      subject: ItemSubject.Intro,
      voice: Voice.Agent,
      author: me,
      to: { circle: false, members: [ben, cy] },
      title: 'Introduce Ben to Cy about clock testing',
      detail:
        'Ben, Cy: you are both fighting timer tests this month. Cy has a fake clock that works; Ben is stuck on flaky clock tests in CI. Worth half an hour. I will leave it to you two.\n\nAda',
      status: ItemStatus.Draft,
      created_at: ago(5),
      review: "Ben's note says he is stuck on flaky clock tests, and Cy wrote that a fake clock fixed theirs. You know both."
    },
    {
      ...base,
      id: 'itm-work',
      kind: ItemKind.Notice,
      subject: ItemSubject.Work,
      voice: Voice.Agent,
      author: me,
      to: { circle: false, members: [me] },
      title: 'Relay answers fork, not revoked_key, to a join replayed after a device revoke',
      detail: 'A join envelope signed by a device revoked after it was written is answered with fork; protocol.md says revoked_key.',
      status: ItemStatus.New,
      created_at: ago(26),
      reviewed_at: ago(25),
      about: 'sha256:' + (1).toString(16).padStart(64, '0'),
      source: {
        before: 'Rotated my laptop key on Tuesday and replayed an old join to check the fold. ',
        quote: 'The relay answered fork, where the protocol says revoked_key',
        after: ', so a node reading it would call it a fork and stop.'
      },
      link: 'https://github.com/digestif-ai/digestif/issues/312',
      review: 'Filed it as digestif-ai/digestif#312, as your Inbox prompt says for work on Digestif.'
    },
    {
      ...base,
      id: 'itm-reply',
      kind: ItemKind.Notice,
      subject: ItemSubject.Work,
      voice: Voice.Agent,
      author: me,
      to: { circle: false, members: [me] },
      title: "Reply to Cy's note",
      detail: 'Your agent drafted a reply for you to read, edit and send.',
      status: ItemStatus.Read,
      created_at: ago(3),
      reviewed_at: ago(3),
      read_at: ago(2),
      about: 'sha256:' + (2).toString(16).padStart(64, '0'),
      review: 'Drafted a reply to Cy'
    },
    {
      ...base,
      id: 'itm-behavior',
      kind: ItemKind.Choice,
      subject: ItemSubject.Behavior,
      voice: Voice.Person,
      author: cy,
      to: { circle: false, members: [me] },
      title: "Install Cy's standup behavior?",
      detail: 'Writes a three-line standup from your record each morning and keeps it on your machine.',
      status: ItemStatus.Read,
      created_at: ago(72),
      reviewed_at: ago(71),
      read_at: ago(70),
      deadline_at: ago(-48),
      options: [
        { id: 'install', label: 'Install', recommended: false },
        { id: 'not_now', label: 'Not now', recommended: true }
      ],
      default_option: 'not_now'
    },
    {
      ...base,
      id: 'itm-mine',
      kind: ItemKind.Question,
      subject: ItemSubject.NoteQuestion,
      voice: Voice.Agent,
      author: me,
      to: { circle: true, members: [] },
      title: 'What made the nightly writer time out on long records?',
      detail: 'The writer times out after 30 minutes on a record of about 400 items. Is anyone else seeing the harness stall?',
      status: ItemStatus.Read,
      done: ItemDone.Closed,
      closed: true,
      created_at: ago(96),
      sent_at: ago(96),
      read_at: ago(96),
      about: 'sha256:' + (3).toString(16).padStart(64, '0'),
      answers: [
        answer(
          11,
          ben,
          Voice.Person,
          'Print mode buffers the whole response before it exits. Stream it and read the line count instead.',
          90
        ),
        answer(12, cy, Voice.Person, 'Not seen it here; our records are short.', 70)
      ],
      close: agentClose,
      closes: [agentClose]
    },
    {
      ...base,
      id: 'itm-asked',
      kind: ItemKind.Question,
      subject: ItemSubject.NoteQuestion,
      voice: Voice.Agent,
      author: me,
      to: { circle: true, members: [] },
      title: 'Which relay region answers fastest from Europe?',
      detail: 'Frankfurt and Amsterdam both answer in under 40ms here; is anyone seeing better?',
      status: ItemStatus.Read,
      created_at: ago(8),
      sent_at: ago(8),
      read_at: ago(8),
      hash: 'sha256:' + (1003).toString(16).padStart(64, '0'),
      about: 'sha256:' + (1).toString(16).padStart(64, '0')
    },
    {
      ...base,
      id: 'itm-cy-notice',
      kind: ItemKind.Notice,
      voice: Voice.Person,
      author: cy,
      to: { circle: false, members: [me] },
      title: 'The fake clock lands in lib-util next week',
      detail: 'Heads up: the clock helpers move into lib-util.',
      status: ItemStatus.Read,
      created_at: ago(30),
      read_at: ago(29)
    },
    {
      ...base,
      id: 'itm-ben-agent-notice',
      kind: ItemKind.Notice,
      voice: Voice.Agent,
      author: ben,
      to: { circle: false, members: [me] },
      title: 'Juno filed the flaky clock tests',
      detail: 'Filed them as one issue.',
      status: ItemStatus.Read,
      created_at: ago(31),
      read_at: ago(30)
    },
    {
      ...base,
      id: 'itm-done',
      kind: ItemKind.Question,
      voice: Voice.Person,
      author: dee,
      to: { circle: true, members: [] },
      title: 'Anyone using batch sends for digests?',
      detail: 'Thinking of moving the digest to one batch call a night.',
      status: ItemStatus.Read,
      done: ItemDone.NotForMe,
      archived_at: ago(8 * 24),
      // A question with no answer for a week closes by itself.
      closed: true,
      created_at: ago(9 * 24),
      read_at: ago(9 * 24)
    }
  ];
}
