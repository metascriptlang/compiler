import { readDir, remove, rmdir, removeAll, writeFile, readFile, modifiedTime, ensureDir, exists, realpath, symlink, rename } from "std/fs";
import { writeStderr } from "std/io";
import { IoErrorKind } from "std/io/errors";
import { tmpDir } from "./path";

const STALE_ENTRY_SECONDS = 7 * 24 * 3600;
const STALE_TMP_SECONDS = 3600;
const COLLECT_EVERY_SECONDS = 3600;
const COLLECTED_MARK = ".collected";

export function nowSeconds(): float64 {
	return Date.now() / 1000;
}

function drop(path: string): void {
	const r = remove(path);
	if (!r.ok && r.error.kind != IoErrorKind.NotFound) {
		writeStderr(`warning: cache collection could not remove ${path}: ${r.error.message}\n`);
	}
}

function collectionDue(root: string, now: float64): string {
	const mark = `${root}/${COLLECTED_MARK}`;
	const last = modifiedTime(mark);
	if (last >= 0 && now - last < COLLECT_EVERY_SECONDS) return "";
	const real = realpath(root);
	if (real == "" || !writeFile(mark, "").ok) return "";
	return real;
}

export function collectStaleEntries(root: string, now: float64, suffixesRecordFirst: string[], staleSeconds: float64 = STALE_ENTRY_SECONDS): void {
	const real = collectionDue(root, now);
	if (real == "") return;
	for (const e of readDir(root)) {
		if (!e.endsWith("/")) continue;
		const name = e.slice(0, e.length - 1);
		const dir = `${root}/${name}`;
		if (realpath(dir) != `${real}/${name}`) continue;
		collectStaleFiles(dir, now, suffixesRecordFirst, staleSeconds);
		rmdir(dir);
	}
}

export function collectStaleFlatEntries(root: string, now: float64, suffixesRecordFirst: string[], staleSeconds: float64 = STALE_ENTRY_SECONDS): void {
	if (collectionDue(root, now) != "") collectStaleFiles(root, now, suffixesRecordFirst, staleSeconds);
}

function collectStaleFiles(dir: string, now: float64, suffixesRecordFirst: string[], staleSeconds: float64): void {
	const owned = (name: string): string | null =>
		suffixesRecordFirst.find((s: string): boolean => name.endsWith(s));
	const stems: string[] = [];
	const newest = new HashMap<string, number>();
	for (const f of readDir(dir)) {
		if (f.endsWith("/")) continue;
		const tmpAt = f.indexOf(".tmp.", 0);
		if (tmpAt >= 0) {
			const old = now - modifiedTime(`${dir}/${f}`) > STALE_TMP_SECONDS;
			if (old && owned(f.slice(0, tmpAt)) != null) drop(`${dir}/${f}`);
			continue;
		}
		const suffix = owned(f);
		if (suffix == null) continue;
		const stem = f.slice(0, f.length - suffix.length);
		const modified = modifiedTime(`${dir}/${f}`);
		const seen = newest.get(stem);
		if (seen == null) stems.push(stem);
		if (seen == null || modified > seen) newest.set(stem, modified);
	}
	for (const stem of stems) {
		if (now - (newest.get(stem) ?? now) <= staleSeconds) continue;
		for (const s of suffixesRecordFirst) {
			drop(`${dir}/${stem}${s}`);
		}
	}
}

export function markUsed(entry: string, now: float64, everySeconds: float64 = COLLECT_EVERY_SECONDS): void {
	const modified = modifiedTime(entry);
	if (modified < 0 || now - modified < everySeconds) return;
	const body = try readFile(entry) catch "";
	const tmp = `${entry}.tmp.${performance.now()}`;
	if (body == "" || !writeFile(tmp, body).ok) return;
	if (!rename(tmp, entry).ok) remove(tmp);
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

const PK = [".pk"];

function text(path: string): string {
	return try readFile(path) catch "missing";
}

test "a sibling stamp and its in-flight tmp survive collection" {
	const root = scratchRoot("stamp-siblings");
	collectStaleEntries(root, nowSeconds(), PK);
	assert exists(`${root}/stampA/entry.pk`);
	assert exists(`${root}/stampB/entry.pk`);
	assert exists(`${root}/stampB/entry.pk.tmp.1`);
	removeAll(root);
}

test "a tmp older than an hour goes, its stamp stays" {
	const root = scratchRoot("stamp-tmp");
	writeFile(`${root}/stampB/notes.txt.tmp.1`, "foreign");
	collectStaleEntries(root, nowSeconds() + STALE_TMP_SECONDS + 60, PK);
	assert exists(`${root}/stampB/entry.pk`);
	assert !exists(`${root}/stampB/entry.pk.tmp.1`);
	assert text(`${root}/stampB/notes.txt.tmp.1`) == "foreign";
	removeAll(root);
}

test "a flat bucket loses every file of a stale entry and keeps foreign files and directories" {
	const root = scratchRoot("stamp-flat");
	const memo = [".sum", ".files"];
	writeFile(`${root}/old.sum`, "sum");
	writeFile(`${root}/old.files`, "files");
	writeFile(`${root}/notes.txt`, "foreign");
	collectStaleFlatEntries(root, nowSeconds() + STALE_ENTRY_SECONDS + 60, memo);
	assert !exists(`${root}/old.sum`);
	assert !exists(`${root}/old.files`);
	assert text(`${root}/notes.txt`) == "foreign";
	assert text(`${root}/stampA/entry.pk`) == "a";
	removeAll(root);
}

test "an entry unwritten past the limit goes from a stamp still in use" {
	const root = scratchRoot("stamp-entry");
	const until = performance.now() + 2100;
	while (performance.now() < until) {}
	writeFile(`${root}/stampA/fresh.pk`, "new");
	collectStaleEntries(root, nowSeconds(), PK, 1.5);
	assert exists(`${root}/stampA/fresh.pk`);
	assert !exists(`${root}/stampA/entry.pk`);
	removeAll(root);
}

test "stamps emptied by collection go, files the collector does not own stay" {
	const root = scratchRoot("stamp-stale");
	writeFile(`${root}/legacy.pk`, "flat");
	writeFile(`${root}/stampB/notes.txt`, "foreign");
	collectStaleEntries(root, nowSeconds() + STALE_ENTRY_SECONDS + 60, PK);
	assert !exists(`${root}/stampA`);
	assert !exists(`${root}/stampB/entry.pk`);
	assert text(`${root}/stampB/notes.txt`) == "foreign";
	assert text(`${root}/legacy.pk`) == "flat";
	removeAll(root);
}

test "a linked stamp directory is not entered" {
	const root = scratchRoot("stamp-link");
	const outside = `${tmpDir()}/msc-stamp-outside-${performance.now()}`;
	ensureDir(outside);
	writeFile(`${outside}/victim.pk`, "outside");
	assert symlink(outside, `${root}/linked`).ok;
	collectStaleEntries(root, nowSeconds() + STALE_ENTRY_SECONDS + 60, PK);
	assert text(`${outside}/victim.pk`) == "outside";
	removeAll(root);
	removeAll(outside);
}

test "a used entry and its companion survive the collection that removes an unused one" {
	const root = scratchRoot("stamp-used");
	writeFile(`${root}/stampA/entry.o`, "object");
	const until = performance.now() + 2100;
	while (performance.now() < until) {}
	markUsed(`${root}/stampA/entry.pk`, nowSeconds(), 1);
	collectStaleEntries(root, nowSeconds(), [".pk", ".o"], 1.5);
	assert text(`${root}/stampA/entry.pk`) == "a";
	assert text(`${root}/stampA/entry.o`) == "object";
	assert !exists(`${root}/stampB/entry.pk`);
	removeAll(root);
}

test "an entry whose mtime cannot be read is collected" {
	const root = scratchRoot("stamp-unreadable");
	assert symlink(`${root}/missing-target`, `${root}/stampA/dangling.pk`).ok;
	assert modifiedTime(`${root}/stampA/dangling.pk`) < 0;
	collectStaleEntries(root, nowSeconds(), PK);
	assert !readDir(`${root}/stampA`).includes("dangling.pk");
	assert exists(`${root}/stampA/entry.pk`);
	removeAll(root);
}
