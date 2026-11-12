import { readFileSync } from 'node:fs'
import type { EndpointDef } from './sql'

/**
 * The columns ClickHouse can find rows by without reading the whole table: the
 * first column of the sort key, each column a skip index covers, and the first
 * column of each projection's sort order. Read from the schema files, so the
 * served spec cannot claim an index the database does not have.
 */
export function indexedColumns(schemaSql: string, projectionsSql: string): Map<string, Set<string>> {
  const byTable = new Map<string, Set<string>>()
  const add = (table: string, column: string) => {
    if (!byTable.has(table)) byTable.set(table, new Set())
    byTable.get(table)!.add(column)
  }
  for (const m of schemaSql.matchAll(
    /CREATE TABLE \w+\.(\w+)\s*\(([\s\S]*?)\n\)\s*ENGINE[^\n]*\n(?:[^\n]*\n)*?ORDER BY \(?`?(\w+)/g,
  )) {
    const [, table, body, leading] = m
    if (leading !== 'tuple') add(table, leading)
    for (const idx of body.matchAll(/INDEX \w+ `?(\w+)`? TYPE/g)) add(table, idx[1])
  }
  for (const m of projectionsSql.matchAll(
    /ALTER TABLE (\w+) ADD PROJECTION[^(]*\([\s\S]*?ORDER BY \(?`?(\w+)/g,
  )) {
    add(m[1], m[2])
  }
  return byTable
}

type Lookup = 'indexed' | 'scan'

const NOTE: Record<Lookup, string> = {
  indexed: 'Indexed: narrows what the server reads.',
  scan:
    'Scans: on its own this reads the whole table. ' +
    'Combine it with an indexed parameter, such as a time range.',
}

interface Parameter {
  name: string
  description?: string
  [key: string]: unknown
}

export interface Spec {
  servers?: unknown
  paths: Record<string, { get?: { parameters?: Parameter[] } }>
}

/**
 * Production's own spec, with each filter parameter marked `x-lookup` and a
 * sentence saying whether it narrows the read. Paging, ordering and the
 * hand-written aggregate endpoints are left as production describes them.
 */
export function annotate(spec: object, defs: EndpointDef[], indexed: Map<string, Set<string>>): Spec {
  const served = structuredClone(spec) as Spec
  delete served.servers
  for (const def of defs) {
    const parameters = served.paths[def.path]?.get?.parameters
    if (!parameters) continue
    const table = def.table.replace(/^[^.]+\./, '')
    for (const p of parameters) {
      const filter = def.filters.find((f) => f.param === p.name)
      if (!filter) continue
      const [alias, column] = filter.column.split('.')
      const lookup: Lookup =
        filter.narrows || (alias === def.alias && indexed.get(table)?.has(column))
          ? 'indexed'
          : 'scan'
      p['x-lookup'] = lookup
      p.description = p.description ? `${p.description}\n\n${NOTE[lookup]}` : NOTE[lookup]
    }
  }
  return served
}

/** The spec this API serves, built once from the files the node runs from. */
export function loadSpec(defs: EndpointDef[]): string {
  const read = (path: string) => readFileSync(new URL(path, import.meta.url), 'utf8')
  const indexed = indexedColumns(read('../../db/schema.sql'), read('../../db/projections.sql'))
  return JSON.stringify(annotate(JSON.parse(read('../openapi.json')), defs, indexed))
}

/** Swagger UI, reading the spec above. */
export const DOCS_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>stride-lite API</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: 'openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>
`
