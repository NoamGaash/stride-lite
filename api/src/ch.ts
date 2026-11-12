import { AsyncLocalStorage } from 'node:async_hooks'
import {
  ClickHouseError as OfficialError,
  ClickHouseLogLevel,
  createClient,
  type ClickHouseSettings,
} from '@clickhouse/client'

const CH_URL = process.env.CH_URL ?? 'http://127.0.0.1:8123'
const CH_USER = process.env.CH_USER ?? 'default'
const CH_PASSWORD = process.env.CH_PASSWORD ?? ''
/**
 * CloudFront stops waiting for the origin after 30 seconds, and ClickHouse does
 * not notice: a query past that point answers nobody and holds the node's cores,
 * once for 43 minutes. Nothing the API serves should take this long.
 */
export const MAX_QUERY_SECONDS = Number(process.env.CH_MAX_QUERY_SECONDS ?? 30)

/**
 * users.xml lets one query use 6 GB, which is the whole node: two heavy visitor
 * queries at once left the enrichment no room, and enrich_route failed with
 * MEMORY_LIMIT_EXCEEDED while allocating 7 MiB. A visitor's query is capped
 * well below that and spills large GROUP BYs and sorts to disk before failing.
 */
export const MAX_QUERY_BYTES = Number(process.env.CH_MAX_QUERY_BYTES ?? 1.5 * 1024 ** 3)

/**
 * The signal of the HTTP request being served. A visitor who leaves aborts the
 * fetch, which closes the connection, and ClickHouse then cancels the query:
 * only because it is read-only, which the API's queries all are.
 */
export const requestSignal = new AsyncLocalStorage<AbortSignal>()

export const QUERY_SETTINGS = {
  max_execution_time: MAX_QUERY_SECONDS,
  max_memory_usage: String(MAX_QUERY_BYTES),
  max_bytes_before_external_group_by: String(MAX_QUERY_BYTES / 2),
  max_bytes_before_external_sort: String(MAX_QUERY_BYTES / 2),
  readonly: '2',
  cancel_http_readonly_queries_on_client_close: 1,
} satisfies ClickHouseSettings

/**
 * Past ClickHouse's own limit, so a slow query ends with its TIMEOUT_EXCEEDED
 * rather than with the client hanging up first and saying only that it did.
 */
export const REQUEST_TIMEOUT_MS = (MAX_QUERY_SECONDS + 5) * 1000

export const client = createClient({
  url: CH_URL,
  username: CH_USER,
  password: CH_PASSWORD,
  request_timeout: REQUEST_TIMEOUT_MS,
  // server.ts already reports each failure once; the client's own log would
  // print every one again, at length.
  log: { level: ClickHouseLogLevel.OFF },
})

export class ClickHouseError extends Error {
  constructor(
    message: string,
    readonly sql: string,
  ) {
    super(message)
  }
}

/** Runs a query and returns the rows as JSON objects. */
export async function query<T = Record<string, unknown>>(sql: string): Promise<T[]> {
  return run(sql, 'JSONEachRow', (rows) => rows.json<T>())
}

/** Runs a query expected to yield a single scalar, e.g. a count. */
export async function scalar(sql: string): Promise<string> {
  return (await run(sql, 'TabSeparated', (rows) => rows.text())).trim()
}

interface Rows {
  json<T>(): Promise<T[]>
  text(): Promise<string>
}

/**
 * The body is read inside, because ClickHouse can fail a query after it has
 * started streaming the answer, and that failure arrives with the body.
 */
async function run<R>(
  sql: string,
  format: 'JSONEachRow' | 'TabSeparated',
  read: (rows: Rows) => Promise<R>,
): Promise<R> {
  const signal = requestSignal.getStore()
  try {
    const rows = await client.query({
      query: sql,
      format,
      clickhouse_settings: QUERY_SETTINGS,
      abort_signal: signal,
    })
    return await read(rows as unknown as Rows)
  } catch (err) {
    // The client words an abort as a plain Error; the signal's own reason is
    // the AbortError that callers check for.
    if (signal?.aborted) throw signal.reason
    if (err instanceof OfficialError) throw new ClickHouseError(err.message.slice(0, 2000), sql)
    throw err
  }
}

/** Single-quoted SQL literal. ClickHouse escapes with backslashes. */
export function lit(value: string | number): string {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`non-finite numeric literal: ${value}`)
    return String(value)
  }
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
}
