import { readDir, remove, removeAll, writeFile, modifiedTime, ensureDir, exists, symlink } from "std/fs";
import { writeStderr } from "std/io";
import { IoErrorKind } from "std/io/errors";
import { tmpDir } from "./path";

const STALE_ENTRY_SECONDS = 7 * 24 * 3600;
const STALE_TMP_SECONDS = 3600;
const COLLECT_EVERY_SECONDS = 3600;
const COLLECTED_MARK = ".collected";

export function nowSeconds(): number {
	return Date.now() / 1000;
}

function collectable(path: string, now: number, limitSeconds: number): boolean {
	const mtime = modifiedTime(path);
	return mtime < 0 || now - mtime > limitSeconds;
}

function drop(path: string, isDir: boolean): void {
	const r = isDir ? removeAll(path) : remove(path);
	if (!r.ok && r.error.kind != IoErrorKind.NotFound) {
		writeStderr(`warning: cache collection could not remove ${path}: ${r.error.message}\n`);
	}
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
		if (collectable(path, now, staleSeconds)) {
			drop(path, isDir);
			continue;
		}
		if (!isDir) continue;
		for (const f of readDir(path)) {
			if (f.endsWith("/")) continue;
			const entry = `${path}/${f}`;
			const limit = f.indexOf(".tmp.", 0) >= 0 ? STALE_TMP_SECONDS : staleSeconds;
			if (collectable(entry, now, limit)) drop(entry, false);
		}
	}
}

function scratchRoot(label: string): string {
	const root = `${tmpDir()}/msc-${label}-${performance.now()}`;
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

test "an entry whose mtime cannot be read is collected" {
	const root = scratchRoot("stamp-unreadable");
	assert symlink(`${root}/missing-target`, `${root}/dangling.pk`).ok;
	assert modifiedTime(`${root}/dangling.pk`) < 0;
	collectStaleEntries(root, nowSeconds());
	assert !readDir(root).includes("dangling.pk");
	removeAll(root);
}
