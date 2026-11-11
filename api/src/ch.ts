import { AsyncLocalStorage } from 'node:async_hooks'

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
 * The signal of the HTTP request being served. A visitor who leaves aborts the
 * fetch, which closes the connection, and ClickHouse then cancels the query:
 * only because it is read-only, which the API's queries all are.
 */
export const requestSignal = new AsyncLocalStorage<AbortSignal>()

export function queryUrl(base = CH_URL): string {
  const url = new URL(base)
  url.searchParams.set('max_execution_time', String(MAX_QUERY_SECONDS))
  url.searchParams.set('readonly', '2')
  url.searchParams.set('cancel_http_readonly_queries_on_client_close', '1')
  return url.toString()
}

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
  const body = await run(`${sql} FORMAT JSONEachRow`)
  if (!body.trim()) return []
  return body
    .trimEnd()
    .split('\n')
    .map((line) => JSON.parse(line) as T)
}

/** Runs a query expected to yield a single scalar, e.g. a count. */
export async function scalar(sql: string): Promise<string> {
  return (await run(`${sql} FORMAT TabSeparated`)).trim()
}

async function run(sql: string): Promise<string> {
  const res = await fetch(queryUrl(), {
    method: 'POST',
    headers: {
      'X-ClickHouse-User': CH_USER,
      'X-ClickHouse-Key': CH_PASSWORD,
      'Content-Type': 'text/plain; charset=utf-8',
    },
    body: sql,
    signal: requestSignal.getStore(),
  })
  const text = await res.text()
  if (!res.ok) throw new ClickHouseError(text.slice(0, 2000), sql)
  return text
}

/** Single-quoted SQL literal. ClickHouse escapes with backslashes. */
export function lit(value: string | number): string {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`non-finite numeric literal: ${value}`)
    return String(value)
  }
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
}
