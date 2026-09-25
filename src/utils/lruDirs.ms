import { readFile, writeFile, readDir, removeAll, rename, remove, isDir, ensureDir, exists } from "std/fs";
import { join } from "std/fs/path";
import { env } from "std/process";

export function dirEntryName(entry: string): string {
	if (entry.length > 1 && entry.charAt(entry.length - 1) == "/") {
		return entry.slice(0, entry.length - 1);
	}
	return entry;
}

function parseLruJournal(raw: string): string[] {
	const keys: string[] = [];
	if (raw == "") return keys;
	for (const line of raw.split("\n")) {
		if (line != "") keys.push(line);
	}
	return keys;
}

export function recordDirUse(root: string, key: string, cap: int32): void {
	const journal = try readFile(join(root, ".lru")) catch "";
	const prev = parseLruJournal(journal);
	const kept: string[] = [];
	const start = prev.length - (cap - 1);
	let i0 = start > 0 ? start : 0;
	while (i0 < prev.length) {
		if (prev[i0] != key) kept.push(prev[i0]);
		i0 = i0 + 1;
	}
	kept.push(key);

	const dirs: string[] = [];
	for (const rawEntry of readDir(root)) {
		const entry = dirEntryName(rawEntry);
		if (isDir(join(root, entry))) dirs.push(entry);
	}
	if (prev.length == 0) {
		for (const d of dirs) {
			if (kept.length >= cap) break;
			let known = false;
			for (const k of kept) { if (k == d) known = true; }
			if (!known) kept.push(d);
		}
	} else if (dirs.length > cap) {
		for (const d of dirs) {
			let live = false;
			for (const k of kept) { if (k == d) live = true; }
			if (!live) removeAll(join(root, d));
		}
	}

	let out = "";
	for (const k of kept) { out = out + k + "\n"; }
	if (out == journal) return;
	const tmp = join(root, `.lru.tmp.${performance.now().toString()}`);
	if (!writeFile(tmp, out).ok) return;
	if (!rename(tmp, join(root, ".lru")).ok) remove(tmp);
}

test "recordDirUse adopts unjournaled dirs, then evicts least-recent past the cap" {
	const base = env.get("TMPDIR");
	const root = join(base != "" ? base : "/tmp", "msc-lrudirs-test");
	const cap: int32 = 4;
	removeAll(root);
	ensureDir(root);
	for (const k of ["a", "b", "c"]) {
		ensureDir(join(root, k));
	}
	recordDirUse(root, "a", cap);
	assert exists(join(root, "b"));
	assert exists(join(root, "c"));
	recordDirUse(root, "b", cap);
	assert exists(join(root, "c"));
	let n = 0;
	while (n < 10) {
		const k = `p${n.toString()}`;
		ensureDir(join(root, k));
		recordDirUse(root, k, cap);
		n = n + 1;
	}
	assert !exists(join(root, "a"));
	assert !exists(join(root, "c"));
	assert exists(join(root, "p9"));
	let dirCount = 0;
	for (const entry of readDir(root)) {
		if (isDir(join(root, dirEntryName(entry)))) dirCount = dirCount + 1;
	}
	assert dirCount <= cap;
	removeAll(root);
}
