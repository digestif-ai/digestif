import {
  ItemAgentAskStatus,
  ItemKind,
  ItemStatus,
  ItemSubject,
  Voice,
  type Item,
  type ItemForm,
  type ItemAnswer,
  type ItemSummary,
  type MemberRef
} from '#generated/ai-digestif-digestif-node.ts';
import type { StatusLabel } from './format.ts';
import { href } from './href.ts';
import { itemThreadKey } from './threads.ts';

// The Inbox's words for an item (DES-51007): its status, its kind, who it is from and whom it is to.
// Kinds stay plain text; only the status has a tone.

const STATUS: Record<ItemStatus, StatusLabel> = {
  [ItemStatus.Draft]: { label: 'Draft', tone: 'info' },
  [ItemStatus.New]: { label: 'New', tone: 'warn' },
  [ItemStatus.Read]: { label: 'Read', tone: 'neutral' },
  [ItemStatus.Done]: { label: 'Done', tone: 'good' }
};
export const itemStatus = (s: ItemStatus): StatusLabel => STATUS[s];

/** Every status an item has, in the order the Inbox lists them. */
export const ITEM_STATUSES: ItemStatus[] = [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read, ItemStatus.Done];

/** What the Inbox asks of the member (DIG-476): who must act next on an item, derived from what the node already says of it. */
export type ItemState = 'you' | 'others' | 'done';

/** The state filters, in the order the menu offers them, with the words the member reads. */
export const ITEM_STATES: { state: ItemState; label: string }[] = [
  { state: 'you', label: 'Waiting on you' },
  { state: 'others', label: 'Waiting on others' },
  { state: 'done', label: 'Done' }
];

/** The states the Inbox opens on: everything but Done, which is hidden by default. */
export const DEFAULT_STATES: ItemState[] = ['you', 'others'];

/**
 * Done is acknowledged, answered or closed; a draft and anything sent to the member wait on them; what the
 * member or their agent sent that someone has acted on, and nobody has closed, waits on the others.
 */
export function itemState(item: Pick<ItemSummary, 'status' | 'closed' | 'author' | 'voice'>, self: string | undefined): ItemState {
  if (item.status === ItemStatus.Done || item.closed) return 'done';
  if (item.status === ItemStatus.Draft || item.voice === Voice.Node || !isMine(item, self)) return 'you';
  return 'others';
}

/** The states checked, from the Inbox's `state` parameters: none given is the default; given empty, none is checked. */
export function checkedStates(params: URLSearchParams): ItemState[] {
  if (!params.has('state')) return DEFAULT_STATES;
  const named = params.getAll('state');
  return ITEM_STATES.map((x) => x.state).filter((s) => named.includes(s));
}

/** The checked states with [s] checked or unchecked, in the menu's order. */
export function toggledState(checked: ItemState[], s: ItemState): ItemState[] {
  return ITEM_STATES.map((x) => x.state).filter((x) => (x === s ? !checked.includes(s) : checked.includes(x)));
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
  [ItemSubject.Practice]: 'Practice',
  [ItemSubject.Suggestion]: 'Prompt suggestion',
  [ItemSubject.Join]: 'Unexpected join',
  [ItemSubject.Paused]: 'Paused',
  [ItemSubject.NoteReady]: 'Notice',
  [ItemSubject.CouldNotRun]: 'Notice',
  [ItemSubject.PauseComing]: 'Notice',
  [ItemSubject.Repositories]: 'Notice',
  [ItemSubject.FolderAccess]: 'Notice',
  [ItemSubject.SkippedProjects]: 'Notice',
  [ItemSubject.InboxAgentFailed]: 'Notice'
};

/** "Question", "Intro", "Work": the subject's name when the item serves one, else its kind's. */
export function itemKind(item: Pick<ItemSummary, 'kind' | 'subject'>): string {
  return item.subject === undefined ? KIND[item.kind] : SUBJECT[item.subject];
}

/** The kinds the Inbox filters by, in the order the menu offers them: every name [itemKind] gives. */
export const ITEM_KINDS: string[] = [...new Set([...Object.values(KIND), ...Object.values(SUBJECT)])];

/** The kinds checked, from the Inbox's `kind` parameters; none checked means every kind shows. */
export const checkedKinds = (params: URLSearchParams): string[] => ITEM_KINDS.filter((k) => params.getAll('kind').includes(k));

/** The checked kinds with [k] checked or unchecked, in the menu's order. */
export const toggledKind = (checked: string[], k: string): string[] =>
  ITEM_KINDS.filter((x) => (x === k ? !checked.includes(k) : checked.includes(x)));

type Addressed = Pick<ItemSummary, 'voice' | 'author' | 'to' | 'status'>;

/** Whether the member wrote it, or their agent or node did for them. */
export const isMine = (item: Pick<ItemSummary, 'author'>, self: string | undefined): boolean => item.author.identity === self;

/**
 * "from Ada Park", "from Juno", "drafted by Hermes", "from your node": an agent by its name alone
 * (ISS-71225, ISS-85463), which the page links to its member and labels with whose agent it is.
 * `agent` is set when the sender is an agent; `lead` is then the words before its name.
 */
export function itemFromParts(item: Addressed, self: string | undefined): { lead: string; agent?: MemberRef } {
  if (item.voice === Voice.Node) return { lead: 'from your node' };
  if (item.voice === Voice.Agent) return { lead: item.status === ItemStatus.Draft ? 'drafted by' : 'from', agent: item.author };
  return { lead: isMine(item, self) ? 'from you' : 'from ' + item.author.name };
}

export function itemFrom(item: Addressed, self: string | undefined): string {
  const p = itemFromParts(item, self);
  return p.agent === undefined ? p.lead : p.lead + ' ' + p.agent.agent_name;
}

/** The Inbox's From column (ISS-64736): "You", "Your node", "Ben Ortiz", and an agent by its name alone, "Hermes", "Juno" (ISS-85463). */
export function itemSender(item: Pick<ItemSummary, 'voice' | 'author'>, self: string | undefined): string {
  if (item.voice === Voice.Node) return 'Your node';
  if (item.voice === Voice.Agent) return item.author.agent_name;
  return isMine(item, self) ? 'You' : item.author.name;
}

/** "to the circle", "to you", "to Ben Ortiz, you". */
export function itemTo(item: Pick<ItemSummary, 'to'>, self: string | undefined): string {
  if (item.to.circle) return 'to the circle';
  const names = item.to.members.map((m) => (m.identity === self ? 'you' : m.name));
  return names.length === 0 ? 'to you' : 'to ' + names.join(', ');
}

/** Who wrote an answer: "Ben Ortiz", "You", or an agent by its name alone, "Juno", its voice saying it is an agent (ISS-85463). */
export function answerer(
  a: Pick<ItemAnswer, 'voice' | 'author'>,
  self: string | undefined
): { name: string; voice: string; agent: boolean } {
  const mine = a.author.identity === self;
  if (a.voice === Voice.Agent) return { name: a.author.agent_name, voice: 'agent', agent: true };
  return { name: mine ? 'You' : a.author.name, voice: 'person', agent: false };
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
  /** Reply: an item another member or their agent sent that is not a question, which is answered (DIG-477). */
  reply: boolean;
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
    close: !draft && mine && item.voice !== Voice.Node && question,
    reply: replyTarget(item, self) !== undefined
  };
}

/**
 * The member a reply to the item goes to (DIG-477): the item's author, when another member or their
 * agent sent it. A draft, the member's own item and their own node's notice have no one to reply to.
 */
export function replyTarget(item: Pick<Item, 'kind' | 'voice' | 'author' | 'status'>, self: string | undefined): MemberRef | undefined {
  if (item.kind === ItemKind.Question || item.status === ItemStatus.Draft || item.voice === Voice.Node || isMine(item, self))
    return undefined;
  return item.author;
}

/** The reply to an item, as the form that sends it: a notice to the item's author, titled for what it answers. */
export function replyForm(
  item: Pick<Item, 'id' | 'kind' | 'title' | 'voice' | 'author' | 'status' | 'about'>,
  text: string,
  self: string | undefined
): ItemForm | undefined {
  const to = replyTarget(item, self);
  if (to === undefined) return undefined;
  const title = item.title.startsWith('Re: ') ? item.title : 'Re: ' + item.title;
  // The reply joins the item's Inbox thread (ISS-85464).
  const about = itemThreadKey(item);
  return {
    ...newItemForm({ kind: 'notice', circle: false, members: [to.identity], title, detail: text.trim(), send: true }, self),
    about
  };
}

/** What a node's notice says of the page where the member acts, by subject. */
const PATH_LABEL: Partial<Record<ItemSubject, string>> = {
  [ItemSubject.Repositories]: 'Choose on Settings, Repositories',
  [ItemSubject.NoteReady]: 'Open the waiting note',
  [ItemSubject.PauseComing]: 'Open the waiting note',
  [ItemSubject.Suggestion]: "Pick tonight's version on your waiting note"
};
export const pathLabel = (item: Pick<Item, 'subject'>): string =>
  (item.subject === undefined ? undefined : PATH_LABEL[item.subject]) ?? 'Open it';

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
  /** Ask your agent when one is connected, a link to connect one when not; only on an open notice with a page (DIG-378). */
  agent?: { action: 'ask'; label: string; disabled: boolean } | { action: 'connect'; label: string; href: string };
}

export function noticeActions(item: Item, view: { self: string | undefined; hostname: string; agentConnected: boolean }): NoticeActions {
  const ownNotice = item.kind === ItemKind.Notice && item.voice === Voice.Node && isMine(item, view.self);
  if (!ownNotice) return item.path === undefined ? {} : { link: { text: pathLabel(item), href: item.path } };
  const page = item.path;
  if (page === undefined) return item.status === ItemStatus.Done ? {} : { acknowledge: 'primary' };
  const onMachine = LOOPBACK.has(view.hostname);
  const where = onMachine
    ? { open: { label: 'Open on your machine', href: page } }
    : item.address === undefined
      ? {}
      : { address: { text: pathLabel(item), address: item.address } };
  // A Done notice keeps its page to look at, and has nothing left to acknowledge or hand over.
  if (item.status === ItemStatus.Done) return where;
  return {
    ...where,
    acknowledge: onMachine ? 'secondary' : 'primary',
    agent: view.agentConnected
      ? { action: 'ask', label: 'Ask your agent', disabled: item.agent_ask?.status === ItemAgentAskStatus.Asked }
      : { action: 'connect', label: 'Connect an agent', href: href.agentEdit() }
  };
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

/** Where an Ask your agent stands, in the member's words; nothing before one is asked, and nothing for a failed one, whose reply is the reason. The agent's own reply is shown beside it. */
export function agentAskText(item: Pick<Item, 'agent_ask'>): string | undefined {
  switch (item.agent_ask?.status) {
    case ItemAgentAskStatus.Asked:
      return 'Asked. The answer arrives as a reply on this notice.';
    case ItemAgentAskStatus.Answered:
      return 'Your agent answered.';
    case ItemAgentAskStatus.Failed:
      return undefined; // the reply says why, and says it all
    default:
      return undefined;
  }
}

/** The answer a close names, when it names one of the question's. */
export function closedOn(item: Item): ItemAnswer | undefined {
  const named = item.close?.answer;
  return named === undefined ? undefined : item.answers.find((a) => a.hash === named);
}

/** One piece of a line of text: plain text, or a link it names. */
export type ReviewPart = { text: string } | { text: string; href: string };

const LINKABLE = /(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])|\b([A-Za-z0-9][\w.-]*\/[\w.-]+)#(\d+)\b/g;
const GITHUB_ITEM = /^https?:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/(?:issues|pull)\/(\d+)\/?$/;
const URL_TEXT_MAX = 60;

/** Where [reviewParts] runs: the node's own app opens this node's pages, the phone app cannot reach them. */
export type LinkOptions = { node?: boolean };

/** A text cut to [URL_TEXT_MAX] characters, ending in an ellipsis when cut. */
function cutText(text: string): string {
  return text.length > URL_TEXT_MAX ? text.slice(0, URL_TEXT_MAX - 1) + '…' : text;
}

/**
 * A URL as a link that reads well (DIG-448): a GitHub issue or pull request as owner/repo#n, and any
 * other URL without its scheme, cut when long. A loopback URL names this node, so it is decided on the
 * host and not the path (ISS-86952): the node app opens its path on the page's own origin, so it works
 * on whichever host and port the app is open, and the phone app, which cannot reach the node, shows it
 * as text. It reads as "note" and the start of its hash for a message on the feed, else as its path.
 */
function urlPart(url: string, node: boolean): ReviewPart {
  const github = GITHUB_ITEM.exec(url);
  if (github !== null) return { text: github[1] + '#' + github[2], href: url };
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return { text: url, href: url };
  }
  if (LOOPBACK.has(parsed.hostname)) {
    const path = parsed.pathname + parsed.search + parsed.hash;
    const text = nodePathText(parsed.pathname) ?? cutText(path);
    return node ? { text, href: path } : { text };
  }
  return { text: cutText(url.replace(/^https?:\/\//, '').replace(/\/$/, '')), href: url };
}

/** A message on the node's feed as "note" and the start of its hash; undefined for any other path. */
function nodePathText(pathname: string): string | undefined {
  const feed = /^\/feed\/([^/]+)$/.exec(pathname);
  if (feed === null || feed[1] === 'new') return undefined;
  let hash = feed[1]!;
  try {
    hash = decodeURIComponent(hash);
  } catch {
    /* keep it as written */
  }
  const value = hash.includes(':') ? hash.slice(hash.indexOf(':') + 1) : hash;
  return 'note ' + value.slice(0, 10);
}

/**
 * A line of text with every URL and owner/repo#n in it as a link (DES-51007, The Inbox agent; DIG-448
 * for an item's own text): a URL opens itself, owner/repo#n opens it on GitHub, which redirects an
 * issue number to its pull request.
 */
export function reviewParts(line: string, options: LinkOptions = {}): ReviewPart[] {
  const node = options.node ?? true;
  const parts: ReviewPart[] = [];
  let at = 0;
  for (const m of line.matchAll(LINKABLE)) {
    const start = m.index;
    if (start > at) parts.push({ text: line.slice(at, start) });
    const [whole, url, repo, number] = m;
    if (url !== undefined) parts.push(urlPart(url, node));
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
