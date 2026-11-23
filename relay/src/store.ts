// One circle's store: a SQLite-backed Durable Object (CircleStore), reached through an adapter that
// presents the D1Database handle the relay's query sites already use, so src/ runs unchanged
// against it (docs/releases.md, Relay releases; DIG-319 measured it with the whole suite). No route
// reads it yet: the release that creates the class carries nothing else, since a rollback cannot
// cross the Durable Object migration that creates it.
//
// The adapter sends each prepared statement, or each batch, to the object as one RPC. The object
// runs a batch inside transactionSync, so a statement that throws rolls back every statement before
// it, as a D1 batch does. A Durable Object's input gate holds other events while a synchronous
// call runs, so each RPC is atomic against every other request on the object; between two RPCs
// another request may commit, as between two D1 round trips.
import { DurableObject } from "cloudflare:workers";
import { SCHEMA, type SchemaMigration } from "./schema.ts";

/** One statement as it crosses the RPC: the SQL and its bind values, already normalised. */
export interface Statement {
  sql: string;
  params: SqlStorageValue[];
}

/** What the object answers for one statement: the rows, as arrays, and D1's meta. */
export interface Answer {
  columns: string[];
  rows: SqlStorageValue[][];
  meta: D1Meta & Record<string, unknown>;
}

/**
 * A refusal crosses the RPC as a value, not a throw: a throw inside the object is logged by the
 * runtime as an uncaught exception on every expected refusal (a lost race, a replayed nonce,
 * link_used), and the adapter rethrows the text on the caller's side, where the relay matches it.
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

/**
 * The table `wrangler d1 migrations apply` keeps, made as wrangler makes it, so the object and a
 * D1 database record their schema the same way and either tool can read which migrations a store
 * holds.
 */
const MIGRATIONS_TABLE = "CREATE TABLE IF NOT EXISTS d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)";

/**
 * Applies to [sql] every migration of [schema] it lacks, in order, each with its d1_migrations row in
 * one transaction, and answers the names it applied. A migration that fails rolls back alone and
 * throws, so the next request tries it again.
 */
export function applySchema(storage: DurableObjectStorage, schema: readonly SchemaMigration[] = SCHEMA): string[] {
  const { sql } = storage;
  sql.exec(MIGRATIONS_TABLE);
  const applied = new Set(sql.exec<{ name: string }>("SELECT name FROM d1_migrations").toArray().map((row) => row.name));
  const added: string[] = [];
  for (const migration of schema) {
    if (applied.has(migration.name)) continue;
    storage.transactionSync(() => {
      for (const query of migration.queries) sql.exec(query);
      sql.exec("INSERT INTO d1_migrations (name) VALUES (?)", migration.name);
    });
    added.push(migration.name);
  }
  return added;
}

export class CircleStore extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // The schema, on first use: every relay migration the object lacks, before any statement runs.
    // SQL storage is synchronous, so the constructor finishes it before the first call is delivered;
    // a failure throws here, and the next call constructs the object and tries again.
    applySchema(ctx.storage);
  }

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
 * src/db.ts keys its per-isolate checks on the handle, so the handle keeps the object's id, outlives
 * requests, and takes a stub per call (no I/O: get() only names the object).
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

/** The handle for one circle: the object named by its root, its id kept and a stub taken per call. */
export function circleDatabase(namespace: DurableObjectNamespace<CircleStore>, root: string): D1Database {
  const id = namespace.idFromName(root);
  return new StoreDatabase(() => namespace.get(id));
}
