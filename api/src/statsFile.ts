import { readFile, rename, writeFile } from "node:fs/promises";
import type { RequestStats, SavedStats } from "./ops";

/** Writes beside the file and renames, so a crash mid-write leaves the last good copy. */
export async function saveStats(
  stats: RequestStats,
  path: string,
): Promise<void> {
  const partial = `${path}.partial`;
  await writeFile(partial, JSON.stringify(stats.snapshot()));
  await rename(partial, path);
}

export async function loadStats(
  stats: RequestStats,
  path: string,
): Promise<void> {
  let saved: SavedStats;
  try {
    saved = JSON.parse(await readFile(path, "utf8"));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT")
      console.error(`ignoring ${path}:`, err);
    return;
  }
  stats.restore(saved);
}
