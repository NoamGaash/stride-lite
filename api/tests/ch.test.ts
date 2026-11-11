import { afterEach, describe, expect, it, vi } from 'vitest'
import { MAX_QUERY_SECONDS, query, queryUrl, requestSignal } from '../src/ch'

afterEach(() => vi.unstubAllGlobals())

describe('queryUrl', () => {
  const params = new URL(queryUrl('http://127.0.0.1:8123')).searchParams

  it('bounds every query by the time the CDN waits', () => {
    expect(params.get('max_execution_time')).toBe(String(MAX_QUERY_SECONDS))
    expect(MAX_QUERY_SECONDS).toBeLessThanOrEqual(30)
  })

  /** Measured on 26.10: the cancel setting does nothing unless the query is read-only. */
  it('has ClickHouse cancel a query whose client has gone', () => {
    expect(params.get('cancel_http_readonly_queries_on_client_close')).toBe('1')
    expect(params.get('readonly')).toBe('2')
  })
})

describe('query', () => {
  it('aborts with the request it serves', async () => {
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) => new Response('{"x":1}\n'))
    vi.stubGlobal('fetch', fetchMock)
    const controller = new AbortController()
    await requestSignal.run(controller.signal, () => query('SELECT 1 AS x'))
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ signal: controller.signal })
  })
})
