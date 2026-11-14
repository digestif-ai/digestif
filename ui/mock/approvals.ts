// The admins' approvals for the mock node (DES-85466; spec/digestif-node.json, /approvals and /signers):
// the circle's signer set, a waiting invite and a waiting promotion, and the operations' rules loosely
// enough to drive Members, Invite, the member page and the approval items. Every approval files one
// Inbox item for the member, sharing the approval object, so a decline shows on both.
import {
  CircleApprovalKind,
  CircleApprovalState,
  ItemKind,
  ItemStatus,
  ItemSubject,
  MemberRole,
  Voice,
  type ApprovalSigner,
  type CircleApproval,
  type Item,
  type Member,
  type MemberRef,
  type NodeError,
  type SignerSet
} from '#generated/ai-digestif-digestif-node.ts';

interface MockResponse {
  status: number;
  body?: unknown;
}

type Route = [string, string, (p: string[], body: unknown, q: URLSearchParams) => MockResponse];

const err = (status: number, code: string, message: string, field?: string): MockResponse => ({
  status,
  body: [{ code, message, ...(field === undefined ? {} : { field: field }) } satisfies NodeError]
});
const ok = (body: unknown, status = 200): MockResponse => ({ status, body });
const str = (body: unknown, name: string): string | undefined => {
  const v = body === null || typeof body !== 'object' ? undefined : (body as Record<string, unknown>)[name];
  return typeof v === 'string' ? v : undefined;
};
const DAY = 86_400_000;

/** What the approvals read from the rest of the mock circle. */
export interface ApprovalsCircle {
  self(): MemberRef;
  /** Every member, with the role the store holds. */
  members(): Member[];
  /** File an Inbox item for the member. */
  file(item: Item): void;
  /** The member's item for an approval that ended: Done. */
  settle(itemId: string): void;
}

/** A member's release key, as the fixtures make one up. */
export const releaseKey = (identity: string): string => 'ed25519:rel' + identity.replace(/^ed25519:/, '').slice(0, 40);

export class MockApprovals {
  set: SignerSet = { signers: [], halted: false };
  approvals: CircleApproval[] = [];
  private nextId = 0;

  constructor(
    private readonly circle: ApprovalsCircle,
    now: Date = new Date()
  ) {
    this.seed(now);
  }

  private ref(m: Member): MemberRef {
    return { identity: m.identity, name: m.name, agent_name: m.agent_name };
  }

  private admins(): Member[] {
    return this.circle.members().filter((m) => m.role === MemberRole.Admin);
  }

  /** The waiting counts, from the signatures. */
  private recount(a: CircleApproval): CircleApproval {
    a.signed_count = a.signers.filter((s) => s.signed).length;
    a.needed_count = a.signers.length + (a.kind === CircleApprovalKind.Promotion && a.added_key === undefined ? 1 : 0);
    const keyless = a.kind === CircleApprovalKind.Promotion && a.added_key === undefined && a.member !== undefined;
    a.waiting_on = keyless
      ? [a.member as MemberRef]
      : a.signers.filter((s) => !s.signed && s.member !== undefined).map((s) => s.member as MemberRef);
    return a;
  }

  private start(form: {
    kind: CircleApprovalKind;
    started_by: MemberRef;
    created_at: string;
    fields: Partial<CircleApproval>;
    signed?: string[];
    /** A seeded approval's item was opened before, so the made-up Inbox's counts stay as they were. */
    opened?: boolean;
  }): CircleApproval {
    this.nextId += 1;
    const id = 'apv-mock' + String(this.nextId);
    const signers: ApprovalSigner[] = this.admins().map((m) => ({
      key: releaseKey(m.identity),
      member: this.ref(m),
      signed: form.signed?.includes(m.identity) === true,
      ...(form.signed?.includes(m.identity) === true ? { signed_at: form.created_at } : {})
    }));
    const a: CircleApproval = {
      id,
      kind: form.kind,
      state: CircleApprovalState.Waiting,
      started_by: form.started_by,
      created_at: form.created_at,
      expires_at: new Date(new Date(form.created_at).getTime() + 7 * DAY).toISOString(),
      waiting_on: [],
      signed_count: 0,
      needed_count: 0,
      signers,
      item: 'itm-' + id,
      ...form.fields
    };
    this.recount(a);
    const self = this.circle.self();
    this.circle.file({
      id: 'itm-' + id,
      kind: ItemKind.Notice,
      subject: ItemSubject.Approval,
      approval: a,
      voice: Voice.Node,
      author: self,
      to: { circle: false, members: [self] },
      title: this.title(a),
      detail: '',
      status: form.started_by.identity === self.identity || form.opened === true ? ItemStatus.Read : ItemStatus.New,
      closed: false,
      created_at: form.created_at,
      local: true,
      options: [],
      answers: [],
      picks: [],
      closes: []
    });
    this.approvals.unshift(a);
    return a;
  }

  private title(a: CircleApproval): string {
    switch (a.kind) {
      case CircleApprovalKind.Invite:
        return 'Invite ' + (a.guest ?? '').replace(/\s*<.*$/, '');
      case CircleApprovalKind.Promotion:
        return 'Promote ' + (a.member?.name ?? '') + ' to Admin';
      case CircleApprovalKind.Removal:
        return 'Remove ' + (a.member?.name ?? '') + ' as Admin';
      case CircleApprovalKind.Replacement:
        return "Replace a signer's key";
    }
  }

  /** Ada, Ben and Cy are the admins. Ben invited Gil, which waits on Ada; Cy promoted Dee, who has not made her key. */
  private seed(now: Date): void {
    const ago = (hours: number): string => new Date(now.getTime() - hours * 3600_000).toISOString();
    const members = this.circle.members();
    const named = (first: string): Member => {
      const m = members.find((x) => x.name.startsWith(first));
      if (m === undefined) throw new Error('fixture has no ' + first);
      return m;
    };
    this.set = {
      signers: this.admins().map((m) => ({
        key: releaseKey(m.identity),
        name: m.name.split(' ')[0] ?? m.name,
        member: this.ref(m),
        revoked: false
      })),
      halted: false
    };
    const ben = named('Ben');
    const cy = named('Cy');
    const dee = named('Dee');
    this.start({
      kind: CircleApprovalKind.Promotion,
      started_by: this.ref(cy),
      created_at: ago(20),
      opened: true,
      fields: { member: this.ref(dee) }
    });
    this.start({
      kind: CircleApprovalKind.Invite,
      started_by: this.ref(ben),
      created_at: ago(6),
      opened: true,
      signed: [ben.identity, cy.identity],
      fields: {
        guest: 'Gil Hart <gil@hart.dev>',
        role: MemberRole.Member,
        email_subject: 'Join our circle on Digestif',
        email_body:
          'Hi Gil,\n\nGood to meet you at the dinner.\n\nPaste this into a terminal on your Mac or Linux machine:\n\n  {{install_command}}\n\nThis invite is yours alone and works once, until {{expires_at}}.\n\nBen Ortiz'
      }
    });
  }

  routes(): Route[] {
    const found = (id: string | undefined, run: (a: CircleApproval) => MockResponse): MockResponse => {
      const a = this.approvals.find((x) => x.id === id);
      return a === undefined ? err(404, 'not_found', 'Not found.') : run(a);
    };
    return [
      ['GET', 'approvals', (_p, _b, q) => this.list(q)],
      ['POST', 'approvals', (_p, b) => this.create(b)],
      ['POST', 'approvals/:/declines', ([id]) => found(id, (a) => this.decline(a))],
      ['GET', 'signers', () => ok(this.set)],
      // For the tests: revoke a signer's key, which halts invites until a set change without it.
      ['POST', '_revoke', (_p, b) => this.revoke(str(b, 'name') ?? '')]
    ];
  }

  private selfIsAdmin(): boolean {
    return this.admins().some((m) => m.identity === this.circle.self().identity);
  }

  private list(q: URLSearchParams): MockResponse {
    if (!this.selfIsAdmin()) return ok([]);
    const states = q.getAll('state').filter((s) => s !== '');
    if (states.some((s) => !Object.values(CircleApprovalState).includes(s as CircleApprovalState)))
      return err(422, 'state', 'Not a state.', 'state');
    const limit = Number(q.get('limit') ?? '50');
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) return err(422, 'limit', 'Not a valid limit.', 'limit');
    return ok(this.approvals.filter((a) => states.length === 0 || states.includes(a.state)).slice(0, limit));
  }

  private create(body: unknown): MockResponse {
    if (!this.selfIsAdmin()) return err(422, 'not_admin', 'Only an admin starts an approval.');
    const kind = str(body, 'kind') as CircleApprovalKind | undefined;
    const self = this.circle.self();
    const now = new Date().toISOString();
    const removal = kind === CircleApprovalKind.Removal || kind === CircleApprovalKind.Replacement;
    if (this.set.halted && !removal) return err(422, 'halted', 'A revoked key halts invites until a signer-set change without it.');
    if (kind === CircleApprovalKind.Invite) {
      const to = (str(body, 'to') ?? '').trim();
      if (!/^[^<>]*<[^@\s<>]+@[^@\s<>]+>$|^[^@\s<>]+@[^@\s<>]+$/.test(to))
        return err(422, 'invalid', 'Write the name and address, such as Priya Raman <priya@raman.dev>.', 'to');
      const role = str(body, 'role') === MemberRole.Admin ? MemberRole.Admin : MemberRole.Member;
      const fields = { guest: to, role, email_subject: str(body, 'email_subject') ?? '', email_body: str(body, 'email_body') ?? '' };
      return ok(this.start({ kind, started_by: self, created_at: now, fields }), 201);
    }
    if (kind === CircleApprovalKind.Promotion || kind === CircleApprovalKind.Removal) {
      const m = this.circle.members().find((x) => x.identity === str(body, 'member'));
      if (m === undefined) return err(422, 'member', 'Not a member of the circle.', 'member');
      if (kind === CircleApprovalKind.Removal && this.set.signers.length < 3)
        return err(422, 'too_few', 'A signer set keeps at least two keys.', 'member');
      const fields: Partial<CircleApproval> = { member: this.ref(m), ...(removal ? { removed_key: releaseKey(m.identity) } : {}) };
      return ok(this.start({ kind, started_by: self, created_at: now, fields }), 201);
    }
    return err(422, 'kind', 'Not a kind.', 'kind');
  }

  private decline(a: CircleApproval): MockResponse {
    if (a.state !== CircleApprovalState.Waiting) return err(422, 'ended', 'The approval has ended.');
    a.state = CircleApprovalState.Declined;
    a.waiting_on = [];
    if (a.item !== undefined) this.circle.settle(a.item);
    return ok(a);
  }

  private revoke(name: string): MockResponse {
    const s = this.set.signers.find((x) => x.name === name);
    if (s === undefined) return err(404, 'not_found', 'Not a signer.');
    s.revoked = true;
    this.set.halted = true;
    return { status: 204 };
  }
}
