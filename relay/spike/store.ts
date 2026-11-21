// DIG-319 storage spike: one circle's store in its own SQLite-backed Durable Object, reached
// through an adapter that presents the D1Database handle the relay's query sites already use, so
// src/ runs unchanged against it. Evidence for DIG-271 decision 0, not wired into any deployment.
//
// The adapter sends each prepared statement, or each batch, to the object as one RPC. The object
// runs a batch inside transactionSync, so a statement that throws rolls back every statement before
// it, as a D1 batch does. A Durable Object's input gate holds other events while a synchronous
// call runs, so each RPC is atomic against every other request on the object; between two RPCs
// another request may commit, as between two D1 round trips.
import { DurableObject } from "cloudflare:workers";

/** One statement as it crosses the RPC: the SQL and its bind values, already normalised. */
export interface Statement {
  sql: string;
  params: SqlStorageValue[];
}

/** What the object answers for one statement: the rows, as objects or arrays, and D1's meta. */
export interface Answer {
  columns: string[];
  rows: SqlStorageValue[][];
  meta: D1Meta & Record<string, unknown>;
}

/**
 * A refusal crosses the RPC as a value, not a throw: a throw inside the object is logged by the
 * runtime as an uncaught exception on every expected refusal (a lost race, a replayed nonce,
 * link_used), and the adapter rethrows the text on the caller's side either way.
 */
export type Outcome<T> = { ok: T } | { refused: string };

function attempt<T>(work: () => T): Outcome<T> {
  try {
    return { ok: work() };
  } catch (error) {
    return { refused: error instanceof Error ? error.message : String(error) };
  }
}

function settled<T>(outcome: Outcome<T>): T {
  if ("refused" in outcome) throw new Error(outcome.refused);
  return outcome.ok;
}

export class CircleStore extends DurableObject {
  /** One statement, outside any explicit transaction: the object's implicit write coalescing applies. */
  run(statement: Statement): Outcome<Answer> {
    return attempt(() => this.execute(statement));
  }

  /** Statements in order, all or none, as D1's batch(). */
  batch(statements: Statement[]): Outcome<Answer[]> {
    return attempt(() => this.ctx.storage.transactionSync(() => statements.map((statement) => this.execute(statement))));
  }

  /** D1's exec(): the text split on newlines, each line one statement, no bindings. */
  exec(query: string): Outcome<D1ExecResult> {
    return attempt(() => {
      const started = Date.now();
      const lines = query
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line !== "");
      for (const line of lines) this.ctx.storage.sql.exec(line);
      return { count: lines.length, duration: Date.now() - started };
    });
  }

  private execute({ sql, params }: Statement): Answer {
    const started = performance.now();
    const before = this.ctx.storage.sql.databaseSize;
    const cursor = this.ctx.storage.sql.exec(sql, ...params);
    const rows = [...cursor.raw()];
    // changes() and last_insert_rowid() are SQLite's own counters of the statement just run: what
    // D1's meta.changes and meta.last_row_id report.
    const counters = this.ctx.storage.sql.exec<{ changes: number; last: number }>("SELECT changes() AS changes, last_insert_rowid() AS last").one();
    const written = cursor.rowsWritten;
    const after = this.ctx.storage.sql.databaseSize;
    return {
      columns: cursor.columnNames,
      rows,
      meta: {
        duration: performance.now() - started,
        size_after: after,
        rows_read: cursor.rowsRead,
        rows_written: written,
        last_row_id: counters.last,
        changed_db: written > 0 || after !== before,
        // changes() is the count of the last INSERT, UPDATE or DELETE on the connection, so a read
        // reports the write before it. D1 reports 0 for a statement that wrote nothing.
        changes: written > 0 ? counters.changes : 0,
      },
    };
  }
}

/** A bind value as D1 accepts it, or D1's own refusal. */
function normalise(value: unknown): SqlStorageValue {
  if (value === null || typeof value === "string" || typeof value === "number") return value;
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "bigint") return Number(value);
  if (value instanceof ArrayBuffer) return value;
  if (ArrayBuffer.isView(value)) return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
  throw new Error(`D1_TYPE_ERROR: Type '${typeof value}' not supported`);
}

function objects<T>(answer: Answer): T[] {
  return answer.rows.map((row) => Object.fromEntries(answer.columns.map((column, i) => [column, row[i]])) as T);
}

function result<T>(answer: Answer): D1Result<T> {
  return { success: true, meta: answer.meta, results: objects<T>(answer) };
}

/**
 * A stub is an I/O object of the request that made it: a stub kept past that request fails with
 * "Cannot perform I/O on behalf of a different request". The D1 binding has no such limit, and
 * src/db.ts keys its per-isolate checks on the handle, so the handle outlives requests and makes a
 * stub per call (no I/O: get() only names the object).
 */
type Store = () => StoreCalls;

/** The object's methods as the adapter calls them over RPC. */
interface StoreCalls {
  run(statement: Statement): Promise<Outcome<Answer>>;
  batch(statements: Statement[]): Promise<Outcome<Answer[]>>;
  exec(query: string): Promise<Outcome<D1ExecResult>>;
}

class AdapterStatement implements D1PreparedStatement {
  constructor(
    private readonly store: Store,
    readonly sql: string,
    readonly params: SqlStorageValue[] = [],
  ) {}

  bind(...values: unknown[]): D1PreparedStatement {
    return new AdapterStatement(this.store, this.sql, values.map(normalise));
  }

  statement(): Statement {
    return { sql: this.sql, params: this.params };
  }

  private async answer(): Promise<Answer> {
    return settled(await this.store().run(this.statement()));
  }

  first<T = unknown>(colName: string): Promise<T | null>;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  async first<T>(colName?: string): Promise<T | null> {
    const answer = await this.answer();
    const [row] = objects<Record<string, unknown>>(answer);
    if (row === undefined) return null;
    if (colName === undefined) return row as T;
    if (!(colName in row)) throw new Error(`D1_COLUMN_NOTFOUND: Column not found (${colName})`);
    return row[colName] as T;
  }

  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return result<T>(await this.answer());
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return result<T>(await this.answer());
  }

  raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
  async raw<T>(options?: { columnNames?: boolean }): Promise<T[] | [string[], ...T[]]> {
    const answer = await this.answer();
    const rows = answer.rows as T[];
    return options?.columnNames === true ? [answer.columns, ...rows] : rows;
  }
}

/** The D1Database handle over one circle's object. */
export class StoreDatabase implements D1Database {
  constructor(private readonly store: Store) {}

  prepare(query: string): D1PreparedStatement {
    return new AdapterStatement(this.store, query);
  }

  async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    const plain = statements.map((s) => {
      if (!(s instanceof AdapterStatement)) throw new Error("D1_ERROR: a batch takes statements this database prepared");
      return s.statement();
    });
    const answers = settled(await this.store().batch(plain));
    return answers.map((answer) => result<T>(answer));
  }

  async exec(query: string): Promise<D1ExecResult> {
    return settled(await this.store().exec(query));
  }

  withSession(): D1DatabaseSession {
    return {
      prepare: (query: string) => this.prepare(query),
      batch: <T>(statements: D1PreparedStatement[]) => this.batch<T>(statements),
      getBookmark: () => null,
    };
  }

  dump(): Promise<ArrayBuffer> {
    return Promise.reject(new Error("dump() applies only to alpha D1 databases"));
  }
}

/** applyD1Migrations (cloudflare:test) accepts only an object whose constructor is named D1Database. */
Object.defineProperty(StoreDatabase, "name", { value: "D1Database" });

/** The handle for one circle: the object named by its root. */
export function circleDatabase(namespace: DurableObjectNamespace<CircleStore>, root: string): D1Database {
  const id = namespace.idFromName(root);
  return new StoreDatabase(() => namespace.get(id));
}
