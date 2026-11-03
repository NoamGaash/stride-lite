import { createServer } from 'node:http'
import { query, scalar, lit, ClickHouseError } from './ch'
import { buildQuery, BadRequest, BadInput, TzRequired, UnknownOrderField } from './sql'
import { endpoints, getEndpoints } from './registry'

const PORT = Number(process.env.PORT ?? 8080)

const byPath = new Map(endpoints.map((e) => [e.path, e]))
const getByPath = new Map(getEndpoints.map((e) => [e.path, e]))

const DATETIME = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.(\d+))?$/

/**
 * ClickHouse renders a timestamp as "YYYY-MM-DD hh:mm:ss[.ffffff]" and 64-bit
 * integers as strings. Upstream stores these columns naive, relabels them UTC
 * in `DateTimeWithTimeZone.process_result_value`, and lets Python's
 * `isoformat()` render them, which appends `+00:00` and omits the fractional
 * part when it is zero. A bare `YYYY-MM-DD` is a date column and gets neither.
 */
function normalize(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(row)) {
    if (typeof v !== 'string') {
      out[k] = v
      continue
    }
    const m = DATETIME.exec(v)
    if (!m) {
      out[k] = v
      continue
    }
    const micros = (m[3] ?? '').padEnd(6, '0').slice(0, 6)
    const frac = micros === '000000' ? '' : `.${micros}`
    out[k] = `${m[1]}T${m[2]}${frac}+00:00`
  }
  return out
}

/**
 * `join_use_nulls` matters for the outer joins: without it ClickHouse fills an
 * unmatched row with the column type's default, so a siri ride with no GTFS
 * match would report `gtfs_route__line_ref: 0` where production reports null.
 */
const SETTINGS =
  'SETTINGS output_format_json_quote_64bit_integers = 0, join_use_nulls = 1'

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
  const send = (status: number, body: unknown) => {
    const text = typeof body === 'string' ? body : JSON.stringify(body)
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
    res.end(text)
  }

  try {
    if (url.pathname === '/healthz') return send(200, { ok: true })

    const listDef = byPath.get(url.pathname)
    if (listDef) {
      const { sql, isCount } = buildQuery(listDef, url.searchParams)
      if (isCount) return send(200, await scalar(sql))
      const rows = await query(`${sql} ${SETTINGS}`)
      return send(200, rows.map(normalize))
    }

    const getDef = getByPath.get(url.pathname)
    if (getDef) {
      const id = url.searchParams.get('id')
      if (id === null || !/^-?\d+$/.test(id)) throw new BadRequest('id is required')
      const select = getDef.fields.map((f) => `\`${f}\``).join(', ')
      const rows = await query(
        `SELECT ${select} FROM ${getDef.table} WHERE id = ${lit(Number(id))} LIMIT 1 ${SETTINGS}`,
      )
      if (rows.length === 0) return send(404, { detail: 'Not Found' })
      return send(200, normalize(rows[0]))
    }

    return send(404, { detail: 'Not Found' })
  } catch (err) {
    if (err instanceof BadInput) return send(400, { detail: err.message })
    if (err instanceof BadRequest) return send(422, { detail: err.message })
    if (err instanceof TzRequired || err instanceof UnknownOrderField)
      return send(500, { message: err.message })
    if (err instanceof ClickHouseError) {
      console.error('clickhouse error for sql:\n', err.sql, '\n', err.message)
      return send(500, { detail: 'query failed' })
    }
    console.error(err)
    return send(500, { detail: 'internal error' })
  }
})

server.listen(PORT, '127.0.0.1', () => {
  const paths = endpoints.length + getEndpoints.length
  console.log(`stride-lite listening on http://127.0.0.1:${PORT} (${paths} endpoints)`)
})
