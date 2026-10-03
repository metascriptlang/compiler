import { readDir, remove, removeAll, writeFile, modifiedTime, ensureDir, exists } from "std/fs";
import { env } from "std/process";

export const STALE_ENTRY_SECONDS = 7 * 24 * 3600;
export const STALE_TMP_SECONDS = 3600;
const COLLECT_EVERY_SECONDS = 3600;
const COLLECTED_MARK = ".collected";

export function nowSeconds(): number {
	return Date.now() / 1000;
}

export function collectStaleEntries(root: string, now: number, staleSeconds: number = STALE_ENTRY_SECONDS): void {
	const mark = `${root}/${COLLECTED_MARK}`;
	const last = modifiedTime(mark);
	if (last >= 0 && now - last < COLLECT_EVERY_SECONDS) return;
	if (!writeFile(mark, "").ok) return;
	for (const e of readDir(root)) {
		if (e == COLLECTED_MARK) continue;
		const isDir = e.endsWith("/");
		const path = `${root}/${isDir ? e.slice(0, e.length - 1) : e}`;
		const age = now - modifiedTime(path);
		if (age > staleSeconds) {
			if (isDir) removeAll(path);
			else remove(path);
			continue;
		}
		if (!isDir) continue;
		for (const f of readDir(path)) {
			if (f.endsWith("/")) continue;
			const entry = `${path}/${f}`;
			const limit = f.indexOf(".tmp.", 0) >= 0 ? STALE_TMP_SECONDS : staleSeconds;
			if (now - modifiedTime(entry) > limit) remove(entry);
		}
	}
}

function scratchRoot(label: string): string {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : (env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp");
	const root = `${base}/msc-${label}-${performance.now()}`;
	ensureDir(`${root}/stampA`);
	ensureDir(`${root}/stampB`);
	writeFile(`${root}/stampA/entry.pk`, "a");
	writeFile(`${root}/stampB/entry.pk`, "b");
	writeFile(`${root}/stampB/entry.pk.tmp.1`, "in flight");
	return root;
}

test "a sibling stamp and its in-flight tmp survive collection" {
	const root = scratchRoot("stamp-siblings");
	collectStaleEntries(root, nowSeconds());
	assert exists(`${root}/stampA/entry.pk`);
	assert exists(`${root}/stampB/entry.pk`);
	assert exists(`${root}/stampB/entry.pk.tmp.1`);
	removeAll(root);
}

test "a tmp older than an hour goes, its stamp stays" {
	const root = scratchRoot("stamp-tmp");
	collectStaleEntries(root, nowSeconds() + STALE_TMP_SECONDS + 60);
	assert exists(`${root}/stampB/entry.pk`);
	assert !exists(`${root}/stampB/entry.pk.tmp.1`);
	removeAll(root);
}

test "an entry unwritten past the limit goes from a stamp still in use" {
	const root = scratchRoot("stamp-entry");
	const until = performance.now() + 2100;
	while (performance.now() < until) {}
	writeFile(`${root}/stampA/fresh.pk`, "new");
	collectStaleEntries(root, nowSeconds(), 1.5);
	assert exists(`${root}/stampA/fresh.pk`);
	assert !exists(`${root}/stampA/entry.pk`);
	removeAll(root);
}

test "stamps and flat entries unwritten for a week go" {
	const root = scratchRoot("stamp-stale");
	writeFile(`${root}/legacy.pk`, "flat");
	collectStaleEntries(root, nowSeconds() + STALE_ENTRY_SECONDS + 60);
	assert !exists(`${root}/stampA`);
	assert !exists(`${root}/stampB`);
	assert !exists(`${root}/legacy.pk`);
	removeAll(root);
}
