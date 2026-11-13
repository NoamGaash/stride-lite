import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it, expect } from "vitest";
import { RequestStats } from "../src/ops";
import { loadStats, saveStats } from "../src/statsFile";

const HOUR = 3_600_000;
const known = new Set(["/status"]);

describe("the request stats file", () => {
  it("carries the week, and when it began, over to the next process", async () => {
    const path = join(await mkdtemp(join(tmpdir(), "stats-")), "requests.json");
    let now = 100 * HOUR;
    const before = new RequestStats(known, () => now);
    before.record("/status", 200, 5);
    now += HOUR;
    before.record("/status", 500, 9);
    await saveStats(before, path);

    now += HOUR;
    const after = new RequestStats(known, () => now);
    await loadStats(after, path);
    const week = after.summary("week");
    expect(week.from).toBe(new Date(100 * HOUR).toISOString());
    expect(week.rows).toEqual([
      {
        path: "/status",
        endpoint: true,
        requests: 2,
        errors: 1,
        p50_ms: 9,
        p95_ms: 9,
        max_ms: 9,
      },
    ]);
  });

  it("keeps no request older than a week", async () => {
    const path = join(await mkdtemp(join(tmpdir(), "stats-")), "requests.json");
    let now = 100 * HOUR;
    const before = new RequestStats(known, () => now);
    before.record("/status", 200, 5);
    await saveStats(before, path);

    now += 8 * 24 * HOUR;
    const after = new RequestStats(known, () => now);
    await loadStats(after, path);
    expect(after.summary("week").rows).toEqual([]);
  });

  it("starts empty when the file is missing or unreadable", async () => {
    const dir = await mkdtemp(join(tmpdir(), "stats-"));
    await writeFile(join(dir, "bad.json"), "{not json");
    for (const name of ["missing.json", "bad.json"]) {
      const stats = new RequestStats(known);
      await expect(loadStats(stats, join(dir, name))).resolves.toBeUndefined();
      expect(stats.summary("week").rows).toEqual([]);
    }
  });
});
