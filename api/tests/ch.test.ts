import { describe, expect, it } from 'vitest'
import { MAX_QUERY_SECONDS, queryUrl } from '../src/ch'

describe('queryUrl', () => {
  it('bounds every query by the time the CDN waits', () => {
    expect(new URL(queryUrl('http://127.0.0.1:8123')).searchParams.get('max_execution_time')).toBe(
      String(MAX_QUERY_SECONDS),
    )
    expect(MAX_QUERY_SECONDS).toBeLessThanOrEqual(30)
  })
})
