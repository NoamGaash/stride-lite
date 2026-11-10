const CH_URL = process.env.CH_URL ?? 'http://127.0.0.1:8123'
const CH_USER = process.env.CH_USER ?? 'default'
const CH_PASSWORD = process.env.CH_PASSWORD ?? ''

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
  const res = await fetch(CH_URL, {
    method: 'POST',
    headers: {
      'X-ClickHouse-User': CH_USER,
      'X-ClickHouse-Key': CH_PASSWORD,
      'Content-Type': 'text/plain; charset=utf-8',
    },
    body: sql,
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
