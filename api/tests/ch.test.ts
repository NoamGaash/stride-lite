import { ClickHouseError as OfficialError } from '@clickhouse/client'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  client,
  failureDetail,
  MAX_QUERY_BYTES,
  MAX_QUERY_SECONDS,
  query,
  QUERY_SETTINGS,
  REQUEST_TIMEOUT_MS,
  requestSignal,
} from '../src/ch'

afterEach(() => vi.restoreAllMocks())

describe('QUERY_SETTINGS', () => {
  it('bounds every query by the time the CDN waits', () => {
    expect(QUERY_SETTINGS.max_execution_time).toBe(MAX_QUERY_SECONDS)
    expect(MAX_QUERY_SECONDS).toBeLessThanOrEqual(30)
  })

  /** The node has 6.56 GiB for everything; a visitor's query must not take the enrichment's share. */
  it('caps the memory of every query well below the server', () => {
    expect(QUERY_SETTINGS.max_memory_usage).toBe(String(MAX_QUERY_BYTES))
    expect(MAX_QUERY_BYTES).toBeLessThanOrEqual(2 * 1024 ** 3)
  })

  /** Measured on 26.10: the cancel setting does nothing unless the query is read-only. */
  it('has ClickHouse cancel a query whose client has gone', () => {
    expect(QUERY_SETTINGS.cancel_http_readonly_queries_on_client_close).toBe(1)
    expect(QUERY_SETTINGS.readonly).toBe('2')
  })
})

describe('query', () => {
  it('runs with the settings, and aborts with the request it serves', async () => {
    const spy = vi.spyOn(client, 'query').mockResolvedValue({
      json: async () => [{ x: 1 }],
    } as never)
    const controller = new AbortController()
    const rows = await requestSignal.run(controller.signal, () => query('SELECT 1 AS x'))
    expect(rows).toEqual([{ x: 1 }])
    expect(spy.mock.calls[0][0]).toMatchObject({
      query: 'SELECT 1 AS x',
      format: 'JSONEachRow',
      clickhouse_settings: QUERY_SETTINGS,
      abort_signal: controller.signal,
    })
  })

  /** server.ts recognises a visitor who left by the name, and answers no one. */
  it('reports a visitor leaving as an AbortError', async () => {
    const controller = new AbortController()
    vi.spyOn(client, 'query').mockImplementation(async () => {
      controller.abort()
      throw new Error('The user aborted a request.')
    })
    await expect(
      requestSignal.run(controller.signal, () => query('SELECT 1')),
    ).rejects.toMatchObject({ name: 'AbortError' })
  })

  /** The client's own socket timeout must not cut ClickHouse off before its timeout error arrives. */
  it('waits for ClickHouse to time a query out itself', () => {
    expect(REQUEST_TIMEOUT_MS).toBeGreaterThan(MAX_QUERY_SECONDS * 1000)
  })
})

describe('failureDetail', () => {
  const failWith = (type: string) =>
    vi.spyOn(client, 'query').mockRejectedValue(
      new OfficialError({ message: `Code: 1. DB::Exception: ${type}`, code: '1', type }),
    )

  /** The query an unfiltered /stop_arrivals/list runs: production times out on it too. */
  it('tells a visitor whose query ran out of memory to narrow it', async () => {
    failWith('MEMORY_LIMIT_EXCEEDED')
    const err = await query('SELECT 1').catch((e) => e)
    expect(failureDetail(err)).toMatch(/too broad.*filter/i)
  })

  it('tells a visitor whose query ran out of time to narrow it', async () => {
    failWith('TIMEOUT_EXCEEDED')
    const err = await query('SELECT 1').catch((e) => e)
    expect(failureDetail(err)).toMatch(/too broad.*filter/i)
  })

  /** Anything else is this API's own bug, not something the visitor can fix. */
  it('keeps other failures generic', async () => {
    failWith('UNKNOWN_IDENTIFIER')
    const err = await query('SELECT 1').catch((e) => e)
    expect(failureDetail(err)).toBe('query failed')
  })
})
