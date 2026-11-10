import {
  ItemKind,
  ItemStatus,
  ItemSubject,
  Voice,
  type Item,
  type ItemForm,
  type ItemAnswer,
  type ItemSummary,
  type MemberRef
} from '#generated/com-bryzek-digestif-node.ts';
import type { StatusLabel } from './format.ts';

// The Inbox's words for an item (DES-51007): its status, its kind, who it is from and whom it is to.
// Kinds stay plain text; only the status has a tone.

const STATUS: Record<ItemStatus, StatusLabel> = {
  [ItemStatus.Draft]: { label: 'Draft', tone: 'info' },
  [ItemStatus.New]: { label: 'New', tone: 'warn' },
  [ItemStatus.Read]: { label: 'Read', tone: 'neutral' },
  [ItemStatus.Done]: { label: 'Done', tone: 'good' }
};
export const itemStatus = (s: ItemStatus): StatusLabel => STATUS[s];

/** The Inbox's filters, in the order the page offers them. */
export const ITEM_STATUSES: ItemStatus[] = [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read, ItemStatus.Done];

/** The statuses the Inbox opens on, checked (ISS-71225): every one but Done. */
export const DEFAULT_STATUSES: ItemStatus[] = ITEM_STATUSES.filter((s) => s !== ItemStatus.Done);

/** The statuses checked, from the Inbox's `status` parameters: none given is the default; given empty, none is checked. */
export function checkedStatuses(params: URLSearchParams): ItemStatus[] {
  if (!params.has('status')) return DEFAULT_STATUSES;
  const named = params.getAll('status');
  return ITEM_STATUSES.filter((s) => named.includes(s));
}

/** The checked statuses with [s] checked or unchecked, in the filters' order. */
export function toggled(checked: ItemStatus[], s: ItemStatus): ItemStatus[] {
  return ITEM_STATUSES.filter((x) => (x === s ? !checked.includes(s) : checked.includes(x)));
}

const KIND: Record<ItemKind, string> = {
  [ItemKind.Question]: 'Question',
  [ItemKind.Choice]: 'Choice',
  [ItemKind.Notice]: 'Notice'
};

const SUBJECT: Record<ItemSubject, string> = {
  [ItemSubject.NoteQuestion]: 'Question',
  [ItemSubject.Intro]: 'Intro',
  [ItemSubject.Share]: 'Share',
  [ItemSubject.Work]: 'Work',
  [ItemSubject.Credit]: 'Filed',
  [ItemSubject.Behavior]: 'Behavior',
  [ItemSubject.Suggestion]: 'Prompt suggestion',
  [ItemSubject.Join]: 'Unexpected join',
  [ItemSubject.Paused]: 'Paused',
  [ItemSubject.NoteReady]: 'Notice',
  [ItemSubject.CouldNotRun]: 'Notice',
  [ItemSubject.PauseComing]: 'Notice',
  [ItemSubject.Repositories]: 'Notice'
};

/** "Question", "Intro", "Work": the subject's name when the item serves one, else its kind's. */
export function itemKind(item: Pick<ItemSummary, 'kind' | 'subject'>): string {
  return item.subject === undefined ? KIND[item.kind] : SUBJECT[item.subject];
}

type Addressed = Pick<ItemSummary, 'voice' | 'author' | 'to' | 'status'>;

/** Whether the member wrote it, or their agent or node did for them. */
export const isMine = (item: Pick<ItemSummary, 'author'>, self: string | undefined): boolean => item.author.identity === self;

/** "from Ada Park", "from Hermes (Ada Park's agent)", "drafted by Hermes", "from your node": the member's own agent by its name alone (ISS-71225). */
export function itemFrom(item: Addressed, self: string | undefined): string {
  if (item.voice === Voice.Node) return 'from your node';
  const mine = isMine(item, self);
  if (item.voice === Voice.Agent) {
    const agent = item.author.agent_name + (mine ? '' : ' (' + item.author.name + "'s agent)");
    return (item.status === ItemStatus.Draft ? 'drafted by ' : 'from ') + agent;
  }
  return mine ? 'from you' : 'from ' + item.author.name;
}

/** The Inbox's From column (ISS-64736): "You", "Your node", "Hermes" (the member's own agent), "Ben Ortiz", "Juno (Ben Ortiz's agent)". */
export function itemSender(item: Pick<ItemSummary, 'voice' | 'author'>, self: string | undefined): string {
  if (item.voice === Voice.Node) return 'Your node';
  const mine = isMine(item, self);
  if (item.voice === Voice.Agent) return item.author.agent_name + (mine ? '' : ' (' + item.author.name + "'s agent)");
  return mine ? 'You' : item.author.name;
}

/** "to the circle", "to you", "to Ben Ortiz, you". */
export function itemTo(item: Pick<ItemSummary, 'to'>, self: string | undefined): string {
  if (item.to.circle) return 'to the circle';
  const names = item.to.members.map((m) => (m.identity === self ? 'you' : m.name));
  return names.length === 0 ? 'to you' : 'to ' + names.join(', ');
}

/** Who wrote an answer: "Ben Ortiz", "Juno (Ben Ortiz's agent)", "you". */
export function answerer(a: Pick<ItemAnswer, 'voice' | 'author'>, self: string | undefined): { name: string; voice: string } {
  const mine = a.author.identity === self;
  if (a.voice === Voice.Agent) return { name: a.author.agent_name, voice: mine ? 'your agent' : a.author.name + "'s agent" };
  return { name: mine ? 'You' : a.author.name, voice: 'person' };
}

/** What the reader can do on the item's page, decided once from the item and who is reading it. */
export interface ItemActions {
  /** Send, Edit and Discard: a draft is always its author's. */
  draft: boolean;
  answer: boolean;
  notForMe: boolean;
  pick: boolean;
  acknowledge: boolean;
  /** Close, Reopen and Name a different answer: the author's. */
  close: boolean;
}

export function itemActions(item: Item, self: string | undefined): ItemActions {
  const draft = item.status === ItemStatus.Draft;
  const mine = isMine(item, self);
  const open = !draft && !item.closed;
  const done = item.status === ItemStatus.Done;
  const question = item.kind === ItemKind.Question;
  return {
    draft,
    answer: open && question && !mine,
    notForMe: open && question && !mine && !done,
    pick: open && item.kind === ItemKind.Choice && !item.picks.some((p) => p.member.identity === self),
    acknowledge: !draft && item.kind === ItemKind.Notice && !done,
    close: !draft && mine && item.voice !== Voice.Node && question
  };
}

/** What a node's notice says of the page where the member acts, by subject. */
const PATH_LABEL: Partial<Record<ItemSubject, string>> = {
  [ItemSubject.Repositories]: 'Choose on Settings, Repositories',
  [ItemSubject.NoteReady]: 'Open the waiting note',
  [ItemSubject.PauseComing]: 'Open the waiting note',
  [ItemSubject.Suggestion]: "Pick tonight's version on your waiting note"
};
export const pathLabel = (item: Pick<Item, 'subject'>): string => (item.subject === undefined ? undefined : PATH_LABEL[item.subject]) ?? 'Open it';

/** Hosts that mean the node's own machine. */
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

/** What the item's page shows of where the member acts and what the actions are (DIG-355), decided once from the item and who reads it. */
export interface NoticeActions {
  /** "Open on your machine" as a link when the reader is on the node's machine. Only on an open notice from the member's own node. */
  open?: { label: string; href: string };
  /** The page's label and the address to type, when the reader is not on the node's machine. Only on an open notice from the member's own node. */
  address?: { text: string; address: string };
  /** A plain link to the item's own page, for an item that is not such a notice (a prompt suggestion). */
  link?: { text: string; href: string };
  /** Acknowledge is secondary beside an Open link and primary otherwise; absent once the notice is Done. */
  acknowledge?: 'primary' | 'secondary';
  /** Ask your agent when one is connected, a hint to connect one when not; only on an open notice with a page (held in issue 378, not rendered). */
  agent?: 'ask' | 'connect';
}

/** The node's default port, where an address to type points when the reader's own is not known. */
const NODE_PORT = '7420';

export function noticeActions(
  item: Item,
  view: { self: string | undefined; hostname: string; port: string; agentConnected: boolean }
): NoticeActions {
  const ownNotice = item.kind === ItemKind.Notice && item.voice === Voice.Node && isMine(item, view.self);
  if (!ownNotice) return item.path === undefined ? {} : { link: { text: pathLabel(item), href: item.path } };
  const page = item.path;
  if (page === undefined) return item.status === ItemStatus.Done ? {} : { acknowledge: 'primary' };
  const onMachine = LOOPBACK.has(view.hostname);
  const where = onMachine
    ? { open: { label: 'Open on your machine', href: page } }
    : { address: { text: pathLabel(item), address: 'http://127.0.0.1:' + (view.port === '' ? NODE_PORT : view.port) + page } };
  // A Done notice keeps its page to look at, and has nothing left to acknowledge or hand over.
  if (item.status === ItemStatus.Done) return where;
  return { ...where, acknowledge: onMachine ? 'secondary' : 'primary', agent: view.agentConnected ? 'ask' : 'connect' };
}

/**
 * What "Ask your agent" hands the member's agent: the item's id, its kind, its title and its page, and nothing else of the item. The
 * title of a node's notice is a count and never a name; the detail, the path of a repository and the kind of a failure stay here.
 * An item with no page has nothing to hand over.
 */
export interface AgentHandoff {
  item: string;
  kind: ItemKind;
  title: string;
  page: string;
}
export const agentHandoff = (item: Pick<Item, 'id' | 'kind' | 'title' | 'path'>): AgentHandoff | undefined =>
  item.path === undefined ? undefined : { item: item.id, kind: item.kind, title: item.title, page: item.path };

/** The answer a close names, when it names one of the question's. */
export function closedOn(item: Item): ItemAnswer | undefined {
  const named = item.close?.answer;
  return named === undefined ? undefined : item.answers.find((a) => a.hash === named);
}

/** One piece of a review line: text, or a link it names. */
export type ReviewPart = { text: string } | { text: string; href: string };

const LINKABLE = /(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])|\b([A-Za-z0-9][\w.-]*\/[\w.-]+)#(\d+)\b/g;

/**
 * A review line with every URL and owner/repo#n in it as a link (DES-51007, The Inbox agent): a URL
 * opens itself, owner/repo#n opens it on GitHub, which redirects an issue number to its pull request.
 */
export function reviewParts(line: string): ReviewPart[] {
  const parts: ReviewPart[] = [];
  let at = 0;
  for (const m of line.matchAll(LINKABLE)) {
    const start = m.index;
    if (start > at) parts.push({ text: line.slice(at, start) });
    const [whole, url, repo, number] = m;
    if (url !== undefined) parts.push({ text: url, href: url });
    else if (repo !== undefined && number !== undefined)
      parts.push({ text: whole, href: 'https://github.com/' + repo + '/issues/' + number });
    at = start + whole.length;
  }
  if (at < line.length) parts.push({ text: line.slice(at) });
  return parts;
}

/** What a person writes on New item; a share, a behavior and work come only from an agent. */
export type NewItemKind = 'question' | 'notice' | 'intro' | 'suggestion';
export const NEW_ITEM_KINDS: NewItemKind[] = ['question', 'notice', 'intro', 'suggestion'];

/**
 * New item's fields as the node takes them: an intro is a notice to the two people it introduces, a
 * prompt suggestion a choice to its judges with its author among them, and only a question and a
 * notice go to the circle.
 */
export function newItemForm(
  fields: { kind: NewItemKind; circle: boolean; members: string[]; title: string; detail: string; send: boolean },
  self: string | undefined
): ItemForm {
  const { kind, members, title, detail, send } = fields;
  const circle = (kind === 'question' || kind === 'notice') && fields.circle;
  const named = kind === 'suggestion' && self !== undefined && !members.includes(self) ? [self, ...members] : members;
  const shape: Record<NewItemKind, Pick<ItemForm, 'kind' | 'subject'>> = {
    question: { kind: ItemKind.Question },
    notice: { kind: ItemKind.Notice },
    intro: { kind: ItemKind.Notice, subject: ItemSubject.Intro },
    suggestion: { kind: ItemKind.Choice, subject: ItemSubject.Suggestion }
  };
  return { ...shape[kind], circle, ...(circle ? {} : { members: named }), title, detail, send };
}

/** The members an item names, as identities, for the forms that take them. */
export const identities = (members: MemberRef[]): string[] => members.map((m) => m.identity);
