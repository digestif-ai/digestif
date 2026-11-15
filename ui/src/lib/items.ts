import {
  ItemAgentAskStatus,
  ItemKind,
  ItemState,
  ItemStatus,
  ItemSubject,
  ItemWaitingOn,
  Voice,
  type Item,
  type ItemForm,
  type ItemAnswer,
  type ItemSummary,
  type MemberRef
} from '#generated/ai-digestif-digestif-node.ts';
import type { StatusLabel } from './format.ts';
import { href } from './href.ts';

// The Inbox's words for an item (DES-51007): its status, its kind, who it is from and whom it is to.
// Kinds stay plain text; only the status has a tone. Read and unread is the row's weight (ISS-88476).

const STATUS: Record<ItemStatus, StatusLabel> = {
  [ItemStatus.Draft]: { label: 'Draft', tone: 'info' },
  [ItemStatus.New]: { label: 'Unread', tone: 'warn' },
  [ItemStatus.Read]: { label: 'Read', tone: 'neutral' },
  // An older node's word for a settled item; this node never gives it.
  [ItemStatus.Done]: { label: 'Read', tone: 'neutral' }
};
export const itemStatus = (s: ItemStatus): StatusLabel => STATUS[s];

/** Every status an item has, in the order the Inbox lists them. */
export const ITEM_STATUSES: ItemStatus[] = [ItemStatus.Draft, ItemStatus.New, ItemStatus.Read];

/** Bold in the Inbox: a draft to send, or an item the member has not read since its last activity. */
export const isUnread = (item: Pick<ItemSummary, 'status'>): boolean => item.status === ItemStatus.New || item.status === ItemStatus.Draft;

/**
 * The Inbox's views (DIG-476, ISS-88476), in the order the menu offers them: the Inbox itself, then the
 * node's views of it (spec item_state), which only the node can read since only it knows who answered.
 */
export const INBOX_VIEWS: { state: ItemState | undefined; label: string }[] = [
  { state: undefined, label: 'Inbox' },
  { state: ItemState.You, label: 'Waiting on you' },
  { state: ItemState.Others, label: 'Waiting on others' },
  { state: ItemState.Archived, label: 'Archived' }
];

/** The view the Inbox's `state` parameter names; none, or one it does not offer, is the Inbox. */
export function inboxView(params: URLSearchParams): ItemState | undefined {
  const named = params.get('state');
  return INBOX_VIEWS.find((v) => v.state !== undefined && v.state === named)?.state;
}

/** Whom a row waits on, in the Waiting on column: "You: answer", "Ben Ortiz", "Ben Ortiz and 2 others", "The circle"; empty when nobody. */
export function waitingText(item: Pick<ItemSummary, 'waiting'>): string {
  const w = item.waiting;
  if (w === undefined) return '';
  if (w.on === ItemWaitingOn.You) return w.act === undefined ? 'You' : 'You: ' + w.act;
  if (w.circle === true) return 'The circle';
  const names = (w.members ?? []).map((m) => m.name);
  if (names.length === 0) return '';
  if (names.length === 1) return names[0]!;
  const rest = names.length - 1;
  return names[0] + ' and ' + String(rest) + (rest === 1 ? ' other' : ' others');
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
  [ItemSubject.Approval]: 'Approval',
  [ItemSubject.InvitesHalted]: 'Notice',
  [ItemSubject.NoteReady]: 'Notice',
  [ItemSubject.CouldNotRun]: 'Notice',
  [ItemSubject.PauseComing]: 'Notice',
  [ItemSubject.Repositories]: 'Notice',
  [ItemSubject.FolderAccess]: 'Notice',
  [ItemSubject.SkippedProjects]: 'Notice',
  [ItemSubject.InboxAgentFailed]: 'Notice',
  [ItemSubject.SendInvite]: 'Notice'
};

/** "Question", "Intro", "Work": the subject's name when the item serves one, else its kind's. */
export function itemKind(item: Pick<ItemSummary, 'kind' | 'subject'>): string {
  return item.subject === undefined ? KIND[item.kind] : SUBJECT[item.subject];
}

/** The kinds the Inbox filters by, in the order the menu offers them: every name [itemKind] gives. */
export const ITEM_KINDS: string[] = [...new Set([...Object.values(KIND), ...Object.values(SUBJECT)])];

/** What the node filters by for the kinds named (ISS-86956): each subject [itemKind] calls one, and each kind it calls one when the item serves no subject. */
export function kindQuery(names: string[]): { kinds: ItemKind[]; subjects: ItemSubject[] } {
  const named = <K extends string>(table: Record<K, string>): K[] => (Object.keys(table) as K[]).filter((k) => names.includes(table[k]));
  return { kinds: named(KIND), subjects: named(SUBJECT) };
}

/** The kinds checked, from the Inbox's `kind` parameters; none checked means every kind shows. */
export const checkedKinds = (params: URLSearchParams): string[] => ITEM_KINDS.filter((k) => params.getAll('kind').includes(k));

/** The checked kinds with [k] checked or unchecked, in the menu's order. */
export const toggledKind = (checked: string[], k: string): string[] =>
  ITEM_KINDS.filter((x) => (x === k ? !checked.includes(k) : checked.includes(x)));

type Addressed = Pick<ItemSummary, 'voice' | 'author' | 'to' | 'status'>;

/** Whether the member wrote it, or their agent or node did for them. */
export const isMine = (item: Pick<ItemSummary, 'author'>, self: string | undefined): boolean => item.author.identity === self;

/** Whether the member is its only reader: they wrote it, it is not to the circle, and every member it names is the member (DIG-536). A reply on it would reach no one. */
export const onlyMine = (item: Pick<ItemSummary, 'author' | 'to'>, self: string | undefined): boolean =>
  isMine(item, self) && !item.to.circle && item.to.members.every((m) => m.identity === self);

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
  pick: boolean;
  /** Mark sent on a Send invite notice (ISS-88004): the one notice whose acknowledgement is an act of its own. */
  markSent: boolean;
  /** Close, Reopen and Name a different answer: the author's. */
  close: boolean;
  /**
   * Reply: on a notice or a choice another member, their agent or the member sent, which joins the item
   * as an answer does (ISS-88476). A question is answered instead, the node's own items have no one to read one, and nor does an item only the member reads (DIG-536).
   */
  reply: boolean;
  /** Archive, or Move to Inbox once archived, and Mark unread: anything sent (ISS-88476). */
  archive: boolean;
  unread: boolean;
}

export function itemActions(item: Item, self: string | undefined): ItemActions {
  const draft = item.status === ItemStatus.Draft;
  const mine = isMine(item, self);
  const open = !draft && !item.closed;
  const question = item.kind === ItemKind.Question;
  return {
    draft,
    answer: open && question && !mine,
    pick: open && item.kind === ItemKind.Choice && !item.picks.some((p) => p.member.identity === self) && !settlesItself(item),
    markSent: !draft && item.subject === ItemSubject.SendInvite && item.done === undefined,
    close: !draft && mine && item.voice !== Voice.Node && question,
    reply: !draft && !question && item.voice !== Voice.Node && !item.local && !settlesItself(item) && !onlyMine(item, self),
    archive: !draft,
    unread: !draft && item.status === ItemStatus.Read
  };
}

/**
 * An approval ends by its signatures or a decline, and Invites halted is Done once the halt lifts
 * (DES-85466): neither is acknowledged, and neither has a page to hand an agent.
 */
const settlesItself = (item: Pick<Item, 'subject' | 'approval'>): boolean =>
  item.approval !== undefined || item.subject === ItemSubject.Approval || item.subject === ItemSubject.InvitesHalted;

/** What a node's notice says of the page where the member acts, by subject. */
const PATH_LABEL: Partial<Record<ItemSubject, string>> = {
  [ItemSubject.Repositories]: 'Choose on Settings, Repositories',
  [ItemSubject.NoteReady]: 'Open the waiting note',
  [ItemSubject.PauseComing]: 'Open the waiting note',
  [ItemSubject.Suggestion]: "Pick tonight's version on your waiting note",
  [ItemSubject.InvitesHalted]: 'Open what lifts it'
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
  /** Ask your agent when one is connected, a link to connect one when not; only on an open notice with a page (DIG-378). */
  agent?: { action: 'ask'; label: string; disabled: boolean } | { action: 'connect'; label: string; href: string };
}

export function noticeActions(item: Item, view: { self: string | undefined; hostname: string; agentConnected: boolean }): NoticeActions {
  if (settlesItself(item))
    return item.path === undefined || item.approval !== undefined ? {} : { link: { text: pathLabel(item), href: item.path } };
  const ownNotice = item.kind === ItemKind.Notice && item.voice === Voice.Node && isMine(item, view.self);
  if (!ownNotice) return item.path === undefined ? {} : { link: { text: pathLabel(item), href: item.path } };
  const page = item.path;
  if (page === undefined) return {};
  const onMachine = LOOPBACK.has(view.hostname);
  const where = onMachine
    ? { open: { label: 'Open on your machine', href: page } }
    : item.address === undefined
      ? {}
      : { address: { text: pathLabel(item), address: item.address } };
  // A settled notice keeps its page to look at, and has nothing left to hand over.
  if (item.done !== undefined) return where;
  return {
    ...where,
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
