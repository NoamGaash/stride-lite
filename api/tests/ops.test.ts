import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, it, expect } from 'vitest'
import {
  LOG_SOURCES,
  MAX_LINES,
  memo,
  metricsSql,
  parseLogsQuery,
  readLogs,
  redact,
  RequestStats,
  redactRow,
  tailFile,
} from '../src/ops'

describe('redact', () => {
  it.each([
    ['Connection reset by peer, while reading from socket (93.172.10.4:51234)', '(<ip>:51234)'],
    ['peer [2a02:6680:1100:4b3::1]:443', '[<ip>]:443'],
    ['from [::ffff:93.172.10.4]:9000', '[<ip>]:9000'],
    ['client 10.0.0.1 said', 'client <ip> said'],
  ])('hides the address in %s', (text, want) => {
    expect(redact(text)).toContain(want)
    expect(redact(text)).not.toMatch(/93\.172|2a02|10\.0\.0\.1/)
  })

  it('hides the AWS account id in a bucket name and an ARN', () => {
    const line =
      'restoring from s3://stride-lite-backup-123456789012/full/ as arn:aws:iam::123456789012:role/x'
    expect(redact(line)).not.toContain('123456789012')
    expect(redact(line)).toContain('stride-lite-backup-<account>/full/')
    expect(redact(line)).toContain('arn:aws:iam::<account>:role/x')
  })

  it.each([
    '2026-11-10 08:07:00.123 <Warning> merges: 4680000000 rows, 207000000000 bytes',
    'ClickHouse 26.10.1.1600 started',
    '== 2026-11-09 failed, stopping here',
    'snapshot 2026/11/10/08/07',
  ])('leaves %s alone', (line) => {
    expect(redact(line)).toBe(line)
  })

  it('redacts only the columns whose text comes from outside', () => {
    const row = redactRow({ version: '24.3.2.23', exception: 'from 93.172.10.4' })
    expect(row).toEqual({ version: '24.3.2.23', exception: 'from <ip>' })
  })
})

describe('the metrics queries', () => {
  const all = Object.values(metricsSql('stride')).join('\n')

  /**
   * These record each client's address. The metrics read neither, and take
   * latency from the API's own counts instead.
   */
  it.each(['query_log', 'session_log', 'query_thread_log', 'text_log', 'address'])(
    'never read %s',
    (name) => expect(all).not.toContain(name),
  )

  it('select no column wholesale anywhere', () => {
    expect(all).not.toMatch(/\*/)
  })

  /** Where the disk goes: what serves, what only waits to be deleted, and what dominates. */
  it('account for storage beyond the active parts', () => {
    const sql = metricsSql('stride')
    expect(sql.projections).toContain('system.projection_parts')
    expect(sql.storage_not_served).toContain('NOT active')
    expect(sql.storage_not_served).toContain('system.detached_parts')
    expect(sql.columns).toContain('data_compressed_bytes')
  })

  it('read the database they are given', () => {
    expect(metricsSql('prod').tables).toContain("database = 'prod'")
  })

  it('refuse a database name that is not an identifier', () => {
    expect(() => metricsSql("x'; DROP DATABASE x --")).toThrow()
  })
})

describe('the logs endpoint', () => {
  it('serves only the fixed sources', () => {
    expect(() => parseLogsQuery(new URLSearchParams('source=/etc/passwd'))).toThrow()
    expect(() => parseLogsQuery(new URLSearchParams('source=../gtfs'))).toThrow()
    expect(parseLogsQuery(new URLSearchParams('source=gtfs')).sources).toEqual(['gtfs'])
    expect(parseLogsQuery(new URLSearchParams('')).sources).toEqual(Object.keys(LOG_SOURCES))
  })

  it('bounds the number of lines', () => {
    expect(() => parseLogsQuery(new URLSearchParams(`lines=${MAX_LINES + 1}`))).toThrow()
    expect(() => parseLogsQuery(new URLSearchParams('lines=0'))).toThrow()
    expect(() => parseLogsQuery(new URLSearchParams('lines=-1'))).toThrow()
  })

  it('returns the tail of a file, redacted, and says when a log does not exist', async () => {
    const root = await mkdtemp(join(tmpdir(), 'ops-'))
    await mkdir(join(root, 'var/log'), { recursive: true })
    const body = Array.from({ length: 50 }, (_, i) => `line ${i}`).join('\n')
    await writeFile(join(root, 'var/log/stride-gtfs.log'), `${body}\nfetched from 93.172.10.4\n`)

    const got = await readLogs(['gtfs', 'catchup'], 3, root)
    expect(got.gtfs).toEqual({ lines: ['line 48', 'line 49', 'fetched from <ip>'] })
    expect(got.catchup).toEqual({ error: 'no such log yet' })
  })

  it('reads at most a megabyte of a large file, and drops the partial first line', async () => {
    const root = await mkdtemp(join(tmpdir(), 'ops-'))
    const path = join(root, 'big.log')
    const line = 'x'.repeat(99)
    await writeFile(path, `${line}\n`.repeat(30000))
    const lines = await tailFile(path, MAX_LINES * 10)
    expect(lines.length).toBeLessThan(11000)
    expect(lines.every((l) => l === line)).toBe(true)
  })
})

describe('memo', () => {
  it('runs the work once per window, and again after a failure', async () => {
    const cached = memo<number>(60_000)
    let calls = 0
    const work = async () => ++calls
    await cached('k', work)
    await cached('k', work)
    expect(calls).toBe(1)

    await expect(cached('bad', () => Promise.reject(new Error('x')))).rejects.toThrow()
    expect(await cached('bad', work)).toBe(2)
  })
})

describe('RequestStats', () => {
  it('reports the last hour by endpoint, then the commonest other paths by name', () => {
    let now = 0
    const stats = new RequestStats(new Set(['/status', '/gtfs_routes/list']), () => now)
    stats.record('/status', 200, 5)
    now = 30 * 60_000
    for (const ms of [10, 20, 30, 40, 1000]) stats.record('/gtfs_routes/list', 200, ms)
    stats.record('/gtfs_routes/list', 500, 50)
    for (let i = 0; i < 4; i++) stats.record('/wp-admin/setup.php', 404, 1)
    for (let i = 0; i < 3; i++) stats.record('/.env', 404, 1)
    for (const p of ['/a', '/b', '/c', '/d', '/e', '/f']) stats.record(p, 404, 2)

    now = 61 * 60_000
    const rows = stats.lastHour()
    expect(rows[0]).toEqual({
      path: '/gtfs_routes/list',
      endpoint: true,
      requests: 6,
      errors: 1,
      p50_ms: 40,
      p95_ms: 1000,
      max_ms: 1000,
    })
    const others = rows.filter((r) => !r.endpoint)
    expect(others.map((r) => [r.path, r.requests])).toEqual([
      ['/wp-admin/setup.php', 4],
      ['/.env', 3],
      ['/a', 1],
      ['/b', 1],
      ['/c', 1],
      ['other', 3],
    ])
  })

  it('keeps no address and no unbounded path', () => {
    const stats = new RequestStats(new Set())
    stats.record('/93.172.10.4/probe', 404, 1)
    stats.record(`/${'x'.repeat(500)}`, 404, 1)
    const paths = stats.lastHour().map((r) => r.path)
    expect(paths).toContain('/<ip>/probe')
    expect(Math.max(...paths.map((p) => p.length))).toBeLessThanOrEqual(80)
  })
})
