/**
 * /ops/logs and /ops/metrics: what an operator would otherwise need a shell on
 * the node for, published so that anyone can watch the node and help.
 *
 * The one thing it must never carry is a visitor's IP address, and that holds
 * by construction rather than by filtering:
 *
 * - Nothing here serves a request log, because none exists: the API writes only
 *   ClickHouse errors, and ClickHouse sees the API on loopback, never a
 *   visitor. Adding an access log to any source below would break this.
 * - Log sources are a fixed list. There is no path parameter.
 * - Request latency is the API's own count, by endpoint path, in memory. The
 *   node's ClickHouse keeps no query_log, and the one it could keep records
 *   each client's address.
 *
 * `redact` then runs over every free-text value anyway, as a second line, and
 * also hides the AWS account id that the backup bucket and role names carry.
 */
import { execFile } from 'node:child_process'
import { open } from 'node:fs/promises'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

type Source = { file: string } | { unit: string }

export const LOG_SOURCES: Record<string, Source> = {
  'first-load': { file: '/var/log/stride-first-load.log' },
  catchup: { file: '/var/log/stride-catchup.log' },
  gtfs: { file: '/var/log/stride-gtfs.log' },
  clickhouse: { file: '/var/log/clickhouse-server/clickhouse.log' },
  api: { unit: 'stride-api' },
}

export const DEFAULT_LINES = 200
export const MAX_LINES = 2000
/** A tail reads at most this much of a file, however many lines are asked for. */
const MAX_TAIL_BYTES = 1 << 20

const OCTET = '(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)'
const V4 = `${OCTET}(?:\\.${OCTET}){3}`
const IPV4 = new RegExp(`(?<![\\d.])${V4}(?![\\d.]*\\d)`, 'g')
// Three colons at least, so a time of day (08:07:00) is not mistaken for one;
// the tail may be an IPv4 address, as in ::ffff:93.172.10.4.
const IPV6 = new RegExp(`(?<![\\w:])(?:[0-9a-f]{0,4}:){3,7}(?:${V4}|[0-9a-f]{0,4})(?![\\w:.])`, 'gi')
// An account id inside an ARN (…:123456789012:…) or a bucket name (…-123456789012).
const AWS_ACCOUNT = /(?<=[-:])\d{12}(?!\d)/g

export function redact(text: string): string {
  return text.replace(IPV6, '<ip>').replace(IPV4, '<ip>').replace(AWS_ACCOUNT, '<account>')
}

export class UnknownSource extends Error {}

export function parseRequestsQuery(params: URLSearchParams): Window {
  const window = params.get('window') ?? 'hour'
  if (!(window in WINDOWS)) throw new UnknownSource(`window must be one of: ${Object.keys(WINDOWS).join(', ')}`)
  return window as Window
}

export function parseLogsQuery(params: URLSearchParams): { sources: string[]; lines: number } {
  const source = params.get('source')
  if (source !== null && !(source in LOG_SOURCES)) {
    throw new UnknownSource(`source must be one of: ${Object.keys(LOG_SOURCES).join(', ')}`)
  }
  const raw = params.get('lines')
  if (raw !== null && !/^\d{1,4}$/.test(raw)) throw new UnknownSource('lines must be a number')
  const lines = raw === null ? DEFAULT_LINES : Number(raw)
  if (lines < 1 || lines > MAX_LINES) {
    throw new UnknownSource(`lines must be between 1 and ${MAX_LINES}`)
  }
  return { sources: source === null ? Object.keys(LOG_SOURCES) : [source], lines }
}

/** The last `lines` lines of a file, reading no more than MAX_TAIL_BYTES of it. */
export async function tailFile(path: string, lines: number): Promise<string[]> {
  const fh = await open(path, 'r')
  try {
    const { size } = await fh.stat()
    const length = Math.min(size, MAX_TAIL_BYTES)
    const buf = Buffer.alloc(length)
    await fh.read(buf, 0, length, size - length)
    const all = buf.toString('utf-8').split('\n')
    if (all.at(-1) === '') all.pop()
    // A read that starts mid-file starts mid-line.
    if (length < size) all.shift()
    return all.slice(-lines)
  } finally {
    await fh.close()
  }
}

async function tailUnit(unit: string, lines: number): Promise<string[]> {
  const { stdout } = await execFileAsync(
    'journalctl',
    ['--unit', unit, '--lines', String(lines), '--no-pager', '--output', 'short-iso'],
    { timeout: 5000, maxBuffer: 4 * MAX_TAIL_BYTES },
  )
  return stdout.split('\n').filter((l) => l !== '')
}

type LogResult = { lines: string[] } | { error: string }

/** LOG_ROOT prefixes every file path, so tests can point the sources elsewhere. */
export async function readLogs(
  sources: string[],
  lines: number,
  root = process.env.LOG_ROOT ?? '',
): Promise<Record<string, LogResult>> {
  const entries = await Promise.all(
    sources.map(async (name): Promise<[string, LogResult]> => {
      const src = LOG_SOURCES[name]
      try {
        const raw =
          'file' in src ? await tailFile(root + src.file, lines) : await tailUnit(src.unit, lines)
        return [name, { lines: raw.map(redact) }]
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code
        return [name, { error: code === 'ENOENT' ? 'no such log yet' : 'could not read' }]
      }
    }),
  )
  return Object.fromEntries(entries)
}

/** Columns whose text comes from outside our own SQL, and so goes through redact. */
export const FREE_TEXT = new Set([
  'exception',
  'last_error_message',
  'latest_fail_reason',
  'command',
  'query_shape',
])

/**
 * One query per section, so a section a ClickHouse version lacks fails alone.
 * The caller runs them one at a time, to take one query slot from the API's
 * readers and not eight. Each is bounded: a fixed database, a time window or a LIMIT.
 */
export function metricsSql(db: string): Record<string, string> {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(db)) {
    throw new Error(`not a database identifier: ${db}`)
  }
  return {
    server: `SELECT version() AS version, uptime() AS uptime_seconds,
        ${["MemoryResident", "OSMemoryTotal", "OSMemoryAvailable", "LoadAverage1", "LoadAverage15"]
          .map((m) => `(SELECT value FROM system.asynchronous_metrics WHERE metric = '${m}') AS ${m}`)
          .join(',\n        ')}`,
    disks: `SELECT name, free_space, total_space, unreserved_space FROM system.disks`,
    tables: `SELECT table, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk, count() AS parts
      FROM system.parts WHERE database = '${db}' AND active
      GROUP BY table ORDER BY bytes_on_disk DESC`,
    projections: `SELECT table, name AS projection, sum(rows) AS rows,
        sum(bytes_on_disk) AS bytes_on_disk
      FROM system.projection_parts WHERE database = '${db}' AND active
      GROUP BY table, name ORDER BY bytes_on_disk DESC`,
    // Disk that holds no served row: parts replaced by a merge or mutation and
    // not yet removed, parts ClickHouse set aside, and other databases.
    storage_not_served: `SELECT kind, table, parts, bytes_on_disk FROM (
        SELECT 'inactive' AS kind, table, count() AS parts, sum(bytes_on_disk) AS bytes_on_disk
          FROM system.parts WHERE database = '${db}' AND NOT active GROUP BY table
        UNION ALL
        SELECT 'detached', table, count(), sum(bytes_on_disk)
          FROM system.detached_parts WHERE database = '${db}' GROUP BY table
        UNION ALL
        SELECT 'other database', database, count(), sum(bytes_on_disk)
          FROM system.parts WHERE database != '${db}' GROUP BY database)
      ORDER BY bytes_on_disk DESC LIMIT 50`,
    // bytes_on_disk of a part includes its projections, which projection_parts
    // counts again, so the parts' own share is what is left after them.
    storage_by_table: `SELECT p.table AS table, p.rows AS rows, p.parts AS parts,
        p.bytes_on_disk AS bytes_on_disk, p.columns_bytes AS columns_bytes,
        p.columns_uncompressed_bytes AS columns_uncompressed_bytes,
        p.primary_key_bytes AS primary_key_bytes, p.marks_bytes AS marks_bytes,
        p.skip_index_bytes AS skip_index_bytes, ifNull(j.projection_bytes, 0) AS projection_bytes
      FROM (
        SELECT table, sum(rows) AS rows, count() AS parts, sum(bytes_on_disk) AS bytes_on_disk,
          sum(data_compressed_bytes) AS columns_bytes,
          sum(data_uncompressed_bytes) AS columns_uncompressed_bytes,
          sum(primary_key_size) AS primary_key_bytes, sum(marks_bytes) AS marks_bytes,
          sum(secondary_indices_compressed_bytes + secondary_indices_marks_bytes) AS skip_index_bytes
        FROM system.parts WHERE database = '${db}' AND active GROUP BY table) AS p
      LEFT JOIN (
        SELECT table, sum(bytes_on_disk) AS projection_bytes
        FROM system.projection_parts WHERE database = '${db}' AND active GROUP BY table) AS j
      ON p.table = j.table
      ORDER BY bytes_on_disk DESC`,
    skip_indexes: `SELECT table, name, type_full, expr, granularity,
        data_compressed_bytes + marks_bytes AS bytes_on_disk, data_uncompressed_bytes
      FROM system.data_skipping_indices WHERE database = '${db}'
      ORDER BY bytes_on_disk DESC`,
    // normalizeQuery replaces every literal with ?, and the literals are the
    // part a visitor chose. The client's address columns are never selected.
    processes: `SELECT query_kind, elapsed, read_rows, read_bytes, total_rows_approx,
        written_rows, memory_usage, is_internal,
        substring(normalizeQuery(query), 1, 400) AS query_shape
      FROM system.processes WHERE query_id != queryID()
      ORDER BY elapsed DESC LIMIT 50`,
    columns: `SELECT table, name AS column, type, compression_codec,
        data_compressed_bytes, data_uncompressed_bytes
      FROM system.columns WHERE database = '${db}'
      ORDER BY data_compressed_bytes DESC LIMIT 40`,
    // A projection being built is a mutation with parts_to_do counting down,
    // and its running work shows under merges.
    mutations: `SELECT table, substring(command, 1, 500) AS command, create_time, parts_to_do,
        is_done, latest_fail_time, latest_fail_reason
      FROM system.mutations
      WHERE database = '${db}' AND (NOT is_done OR create_time > now() - INTERVAL 7 DAY)
      ORDER BY create_time DESC LIMIT 100`,
    merges: `SELECT table, elapsed, progress, num_parts, is_mutation, total_size_bytes_compressed
      FROM system.merges WHERE database = '${db}' ORDER BY elapsed DESC LIMIT 100`,
    refreshes: `SELECT view, status, last_success_time, last_success_duration_ms,
        last_refresh_time, next_refresh_time, exception, retry
      FROM system.view_refreshes WHERE database = '${db}' ORDER BY view`,
    errors_last_day: `SELECT name, code, value, last_error_time, last_error_message
      FROM system.errors WHERE last_error_time > now() - INTERVAL 1 DAY
      ORDER BY last_error_time DESC LIMIT 50`,
  }
}

export function redactRow(row: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(row).map(([k, v]) => [k, FREE_TEXT.has(k) && typeof v === 'string' ? redact(v) : v]),
  )
}

/**
 * Both endpoints are cheap but public, so a burst of requests with distinct
 * query strings, which the CDN would pass through, still reaches the node once
 * per window.
 */
export function memo<T>(ttlMs: number): (key: string, make: () => Promise<T>) => Promise<T> {
  const cache = new Map<string, { at: number; value: Promise<T> }>()
  return (key, make) => {
    const now = Date.now()
    const hit = cache.get(key)
    if (hit && now - hit.at < ttlMs) return hit.value
    for (const [k, v] of cache) if (now - v.at >= ttlMs) cache.delete(k)
    const value = make()
    cache.set(key, { at: now, value })
    value.catch(() => cache.delete(key))
    return value
  }
}

type Sample = { at: number; path: string; endpoint: boolean; status: number; ms: number }

type Row = {
  path: string
  endpoint: boolean
  requests: number
  errors: number
  p50_ms: number
  p95_ms: number
  max_ms: number
}

const MINUTE_MS = 60_000
const HOUR_MS = 60 * MINUTE_MS
/** Each window, and the width of the buckets it is charted in. */
export const WINDOWS = {
  hour: { ms: HOUR_MS, bucketMs: 5 * MINUTE_MS },
  day: { ms: 24 * HOUR_MS, bucketMs: HOUR_MS },
  week: { ms: 7 * 24 * HOUR_MS, bucketMs: HOUR_MS },
} as const
export type Window = keyof typeof WINDOWS
const MAX_SAMPLES = 500_000
/** How many paths that are not endpoints are named; the rest fold into "other". */
const NAMED_OTHER_PATHS = 5
const MAX_PATH_LENGTH = 80

function percentile(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
}

function summarise(path: string, endpoint: boolean, list: Sample[]): Row {
  const ms = list.map((s) => s.ms).sort((x, y) => x - y)
  return {
    path,
    endpoint,
    requests: list.length,
    errors: list.filter((s) => s.status >= 500).length,
    p50_ms: Math.round(percentile(ms, 0.5)),
    p95_ms: Math.round(percentile(ms, 0.95)),
    max_ms: Math.round(ms[ms.length - 1]),
  }
}

type Bucket = { start: string; requests: number; errors: number; p95_ms: number | null }

/** `from` is where the API's memory of requests begins, which after a restart is later than the window's start. */
type Summary = { window: Window; from: string; to: string; buckets: Bucket[]; rows: Row[] }

/**
 * The last week of requests, in memory only, by path. `known` is the set of paths the API
 * serves. Of the rest, which are scanners and typos, only the commonest few
 * are named and everything else is one "other" row, so a crawler cannot grow
 * the report one made-up path at a time. Those paths are cut short and
 * redacted; the query string is never seen, and nothing about the requester
 * is kept.
 */
export class RequestStats {
  private samples: Sample[] = []
  private startedAt: number
  /** Past MAX_SAMPLES the oldest are dropped, and the summary must not claim them. */
  private forgotBefore = 0

  constructor(
    private readonly known: ReadonlySet<string>,
    private readonly now: () => number = Date.now,
  ) {
    this.startedAt = now()
  }

  record(path: string, status: number, ms: number): void {
    const endpoint = this.known.has(path)
    const name = endpoint ? path : redact(path).slice(0, MAX_PATH_LENGTH)
    this.samples.push({ at: this.now(), path: name, endpoint, status, ms })
    if (this.samples.length > MAX_SAMPLES) {
      const dropped = this.samples.splice(0, this.samples.length - MAX_SAMPLES)
      this.forgotBefore = dropped[dropped.length - 1].at
    }
  }

  summary(window: Window): Summary {
    const now = this.now()
    const { ms, bucketMs } = WINDOWS[window]
    const weekAgo = now - WINDOWS.week.ms
    this.samples = this.samples.filter((s) => s.at > weekAgo)
    const since = now - ms
    const inWindow = this.samples.filter((s) => s.at > since)
    const count = ms / bucketMs
    const buckets = Array.from({ length: count }, (): Sample[] => [])
    for (const s of inWindow) buckets[Math.min(count - 1, Math.floor((s.at - since) / bucketMs))].push(s)
    return {
      window,
      from: new Date(Math.max(since, this.startedAt, this.forgotBefore)).toISOString(),
      to: new Date(now).toISOString(),
      buckets: buckets.map((list, i) => ({
        start: new Date(since + i * bucketMs).toISOString(),
        requests: list.length,
        errors: list.filter((s) => s.status >= 500).length,
        p95_ms: list.length ? Math.round(percentile(list.map((s) => s.ms).sort((x, y) => x - y), 0.95)) : null,
      })),
      rows: byPathRows(inWindow),
    }
  }

  lastHour(): Row[] {
    return this.summary('hour').rows
  }

  snapshot(): SavedStats {
    return { startedAt: this.startedAt, forgotBefore: this.forgotBefore, samples: this.samples }
  }

  /** Takes over a previous process's memory, so a restart does not read as a quiet week. */
  restore(saved: SavedStats): void {
    const weekAgo = this.now() - WINDOWS.week.ms
    this.samples = [...saved.samples.filter((s) => s.at > weekAgo), ...this.samples].slice(-MAX_SAMPLES)
    this.startedAt = Math.min(this.startedAt, saved.startedAt)
    this.forgotBefore = Math.max(this.forgotBefore, saved.forgotBefore)
  }
}

export type SavedStats = { startedAt: number; forgotBefore: number; samples: Sample[] }

function byPathRows(samples: Sample[]): Row[] {
  const byPath = new Map<string, Sample[]>()
  for (const s of samples) {
    const list = byPath.get(s.path)
    if (list) list.push(s)
    else byPath.set(s.path, [s])
  }
  const commonestFirst = (x: Row, y: Row) => y.requests - x.requests || x.path.localeCompare(y.path)
  const rows = [...byPath].map(([path, list]) => summarise(path, list[0].endpoint, list))
  const endpoints = rows.filter((r) => r.endpoint).sort(commonestFirst)
  const others = rows.filter((r) => !r.endpoint).sort(commonestFirst)
  const rest = others.slice(NAMED_OTHER_PATHS).flatMap((r) => byPath.get(r.path) ?? [])
  return [
    ...endpoints,
    ...others.slice(0, NAMED_OTHER_PATHS),
    ...(rest.length ? [summarise('other', false, rest)] : []),
  ]
}
