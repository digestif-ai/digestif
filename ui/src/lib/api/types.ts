// The models of spec/digestif-node.json, the node's local API. Keep this file in step with the
// spec field for field; it is replaced by generated types once the repo's codegen covers the spec.

export type Voice = 'person' | 'agent';
export type MessageStatus = 'posted' | 'awaiting_approval' | 'refused' | 'failed' | 'retracted';
export type AskKind = 'intro' | 'meeting' | 'share' | 'behavior' | 'join';
export type AskStatus = 'open' | 'answered' | 'lapsed' | 'withdrawn';
export type MemberStatus = 'active' | 'silent' | 'revoked';
export type SilenceReason = 'asleep' | 'no_sources' | 'harness_signed_out' | 'relay_rejecting' | 'deny_refusing';
export type GuestStatus = 'invited' | 'joined' | 'expired' | 'revoked';
export type SourceKind = 'claude_code' | 'git';
export type DenyEntryKind = 'name' | 'domain' | 'id' | 'pattern';

export interface NodeError {
  code: string;
  message: string;
  field?: string;
}

export interface NodeStatus {
  member_name?: string;
  agent_name?: string;
  first_run: boolean;
  open_asks: number;
  notes_awaiting_approval: number;
  approvals_required: number;
}

export interface MemberRef {
  identity: string;
  name: string;
  agent_name: string;
}

export interface FeedItem {
  hash: string;
  kind: string;
  voice: Voice;
  author: MemberRef;
  recipient?: MemberRef;
  created_at: string;
  status: MessageStatus;
  preview: string;
}

export interface Message {
  hash: string;
  kind: string;
  voice: Voice;
  author: MemberRef;
  recipient?: MemberRef;
  created_at: string;
  status: MessageStatus;
  text?: string;
  reply_to?: string;
  refused_rule?: string;
  replies: FeedItem[];
}

export interface PostForm {
  text: string;
  reply_to?: string;
}

export interface AskOption {
  id: string;
  label: string;
  recommended: boolean;
}

export interface AskAnswer {
  option_id: string;
  answered_at: string;
}

export interface AskSummary {
  id: string;
  kind: AskKind;
  title: string;
  status: AskStatus;
  from?: MemberRef;
  deadline_at: string;
  created_at: string;
}

export interface Ask extends AskSummary {
  detail: string;
  options: AskOption[];
  on_no_answer: string;
  message?: string;
  answer?: AskAnswer;
}

export interface MemberSummary {
  identity: string;
  name: string;
  agent_name: string;
  status: MemberStatus;
  last_posted_at?: string;
  silence_reason?: SilenceReason;
  muted: boolean;
  is_self: boolean;
}

export interface Device {
  key: string;
  role: string;
  admitted_at: string;
  revoked_at?: string;
}

export interface Member extends MemberSummary {
  joined_at: string;
  devices: Device[];
  recent: FeedItem[];
}

export interface Guest {
  name: string;
  status: GuestStatus;
  expires_at: string;
  identity?: string;
}

export interface DinnerSummary {
  hash: string;
  date: string;
  label: string;
  host: MemberRef;
  guests: number;
  joined: number;
}

export interface Dinner {
  hash: string;
  date: string;
  label: string;
  host: MemberRef;
  guests: Guest[];
  relays: string[];
}

export interface Brief {
  text: string;
  updated_at?: string;
}

export interface Source {
  id: string;
  kind: SourceKind;
  label: string;
  paths: string[];
  yields: string[];
  selected: boolean;
}

export interface NotePreview {
  text?: string;
  refused_rule?: string;
  extracted: string[];
}

export interface Detector {
  name: string;
  description: string;
}

export interface DenyEntry {
  id: string;
  kind: DenyEntryKind;
  value: string;
  created_at: string;
  trips: number;
}

export interface Rules {
  text: string;
  updated_at?: string;
  deny: DenyEntry[];
  detectors: Detector[];
}

export interface ApprovalQueue {
  approved: number;
  required: number;
  notes: FeedItem[];
}
