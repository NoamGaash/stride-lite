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
export const FREE_TEXT = new Set(['exception', 'last_error_message', 'latest_fail_reason', 'command'])

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
    columns: `SELECT table, name AS column, type, compression_codec,
        data_compressed_bytes, data_uncompressed_bytes
      FROM system.columns WHERE database = '${db}'
      ORDER BY data_compressed_bytes DESC LIMIT 30`,
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

type Sample = { at: number; path: string; status: number; ms: number }

const HOUR_MS = 3_600_000
const MAX_SAMPLES = 200_000

function percentile(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
}

/**
 * The last hour of requests, by path. `known` is the set of paths the API
 * serves; anything else counts as "other", so a crawler cannot grow the
 * report one made-up path at a time. Nothing about the requester is kept.
 */
export class RequestStats {
  private samples: Sample[] = []

  constructor(
    private readonly known: ReadonlySet<string>,
    private readonly now: () => number = Date.now,
  ) {}

  record(path: string, status: number, ms: number): void {
    this.samples.push({ at: this.now(), path: this.known.has(path) ? path : 'other', status, ms })
    if (this.samples.length > MAX_SAMPLES) this.samples.splice(0, this.samples.length - MAX_SAMPLES)
  }

  lastHour(): { path: string; requests: number; errors: number; p50_ms: number; p95_ms: number; max_ms: number }[] {
    const since = this.now() - HOUR_MS
    this.samples = this.samples.filter((s) => s.at > since)
    const byPath = new Map<string, Sample[]>()
    for (const s of this.samples) {
      const list = byPath.get(s.path)
      if (list) list.push(s)
      else byPath.set(s.path, [s])
    }
    return [...byPath]
      .map(([path, list]) => {
        const ms = list.map((s) => s.ms).sort((x, y) => x - y)
        return {
          path,
          requests: list.length,
          errors: list.filter((s) => s.status >= 500).length,
          p50_ms: Math.round(percentile(ms, 0.5)),
          p95_ms: Math.round(percentile(ms, 0.95)),
          max_ms: Math.round(ms[ms.length - 1]),
        }
      })
      .sort((x, y) => y.requests - x.requests)
  }
}
