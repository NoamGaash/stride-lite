import { createServer } from 'node:http'
import { gzip } from 'node:zlib'
import { promisify } from 'node:util'
import { query, scalar, lit, ClickHouseError } from './ch'
import { buildQuery, BadRequest, BadInput, TzRequired, UnknownOrderField } from './sql'
import { endpoints, getEndpoints } from './registry'
import { rawEndpoints, wrap, type RawEndpointDef } from './raw'

const PORT = Number(process.env.PORT ?? 8080)
const HOST = process.env.HOST ?? '0.0.0.0'

const byPath = new Map(endpoints.map((e) => [e.path, e]))
const getByPath = new Map(getEndpoints.map((e) => [e.path, e]))
const rawByPath = new Map(rawEndpoints.map((e) => [e.path, e]))
const DB = process.env.CH_DB ?? 'stride'

/**
 * Applies the response model's own coercions. A field declared `datetime.date`
 * on a timestamp column renders as a bare day, and one declared `str` on an
 * integer column renders quoted; both change the bytes a client sees. `shape`
 * then fixes the key order and fills every declared field, because FastAPI
 * emits all of a response model's fields whether the query produced them or not.
 */
function shapeRow(def: RawEndpointDef, row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(row)) {
    const how = def.coerce?.[k]
    if (how === 'date' && typeof v === 'string') out[k] = v.slice(0, 10)
    else if (how === 'string' && v !== null && v !== undefined) out[k] = String(v)
    else out[k] = v
  }
  if (!def.shape) return out
  const ordered: Record<string, unknown> = {}
  for (const k of def.shape) ordered[k] = k in out ? out[k] : null
  return ordered
}

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

const gzipAsync = promisify(gzip)

/**
 * Below this, the header costs more than the compression saves.
 */
const MIN_GZIP_BYTES = 1024

/**
 * CloudFront's automatic compression only applies to an origin response that
 * carries `Content-Length`, and Node sends a bare `res.end(text)` chunked. So
 * these responses would reach every viewer uncompressed: measured 33,349 bytes
 * against 3,075 gzipped on one 100-row response, which is the egress bill off
 * by a factor of ten. Compressing at the origin fixes it whatever the CDN does,
 * and CloudFront passes an already-encoded body straight through.
 */
/**
 * Upstream mounts `CORSMiddleware(allow_origins='*')`, whose defaults are
 * narrower than they look: `GET` is the only allowed method and the allowed
 * headers are the CORS-safelisted four. Measured against production rather than
 * assumed, because a frontend on another origin sees nothing without them.
 */
const PREFLIGHT_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET',
  'Access-Control-Max-Age': '600',
  'Access-Control-Allow-Headers': 'Accept, Accept-Language, Content-Language, Content-Type',
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
  const wantsGzip = /\bgzip\b/.test(req.headers['accept-encoding'] ?? '')

  if (
    req.method === 'OPTIONS' &&
    req.headers.origin !== undefined &&
    req.headers['access-control-request-method'] !== undefined
  ) {
    res.writeHead(200, {
      ...PREFLIGHT_HEADERS,
      'Content-Type': 'text/plain; charset=utf-8',
      'Content-Length': '2',
    })
    return res.end('OK')
  }

  const send = async (status: number, body: unknown) => {
    const text = typeof body === 'string' ? body : JSON.stringify(body)
    const raw = Buffer.from(text, 'utf-8')
    const headers: Record<string, string> = {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      Vary: 'Accept-Encoding',
    }
    const payload =
      wantsGzip && raw.length >= MIN_GZIP_BYTES ? await gzipAsync(raw) : raw
    if (payload !== raw) headers['Content-Encoding'] = 'gzip'
    headers['Content-Length'] = String(payload.length)
    res.writeHead(status, headers)
    res.end(payload)
  }

  try {
    if (url.pathname === '/healthz') return await send(200, { ok: true })

    const listDef = byPath.get(url.pathname)
    if (listDef) {
      const { sql, isCount } = buildQuery(listDef, url.searchParams)
      if (isCount) return await send(200, await scalar(sql))
      const rows = await query(`${sql} ${SETTINGS}`)
      return await send(200, rows.map(normalize))
    }

    const rawDef = rawByPath.get(url.pathname)
    if (rawDef) {
      const { sql, isCount } = wrap(rawDef, rawDef.build(url.searchParams, DB), url.searchParams)
      if (isCount) return await send(200, await scalar(sql))
      const rows = await query(`${sql} ${SETTINGS}`)
      return await send(200, rows.map((r) => shapeRow(rawDef, normalize(r))))
    }

    const getDef = getByPath.get(url.pathname)
    if (getDef) {
      const id = url.searchParams.get('id')
      if (id === null || !/^-?\d+$/.test(id)) throw new BadRequest('id is required')
      const select = getDef.fields.map((f) => `\`${f}\``).join(', ')
      const rows = await query(
        `SELECT ${select} FROM ${getDef.table} WHERE id = ${lit(Number(id))} LIMIT 1 ${SETTINGS}`,
      )
      if (rows.length === 0) return await send(404, { detail: 'Not Found' })
      return await send(200, normalize(rows[0]))
    }

    return await send(404, { detail: 'Not Found' })
  } catch (err) {
    if (err instanceof BadInput) return await send(400, { detail: err.message })
    if (err instanceof BadRequest) return await send(422, { detail: err.message })
    if (err instanceof TzRequired || err instanceof UnknownOrderField)
      return await send(500, { message: err.message })
    if (err instanceof ClickHouseError) {
      console.error('clickhouse error for sql:\n', err.sql, '\n', err.message)
      return await send(500, { detail: 'query failed' })
    }
    console.error(err)
    return await send(500, { detail: 'internal error' })
  }
})

/**
 * Both places this runs reach it from outside its own network namespace: the
 * deployed instance answers CloudFront on port 80 with no proxy in front, and a
 * dev container is reached through forwarding. A loopback bind refuses both. The
 * boundary is the security group, which opens port 80 and nothing else.
 */
server.listen(PORT, HOST, () => {
  const paths = endpoints.length + getEndpoints.length + rawEndpoints.length
  console.log(`stride-lite listening on http://${HOST}:${PORT} (${paths} endpoints)`)
})
