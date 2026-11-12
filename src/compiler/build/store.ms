import { exists, readFile, ensureDir, removeAll, rename } from "std/fs";
import { join } from "std/fs/path";
import { hashContent } from "../../utils/contentHash";
import { globalCacheRoot } from "../../utils/cachePaths";
import { markUsed, nowSeconds, collectStaleFlatEntries, collectStaleTrees } from "../../utils/stampDirs";
import { atomicWriteFile } from "../io";

export function stepStoreRoot(): string {
	const root = globalCacheRoot();
	return root == "" ? "" : join(root, "build");
}

function manifestOf(store: string, key: string): string {
	return `${store}/m/${hashContent(key)}.m`;
}

const MANIFEST_ENTRIES = 16;

function manifestEntries(manifest: string): string[][] {
	const entries: string[][] = [];
	for (const line of (exists(manifest) ? (try readFile(manifest) catch "") : "").split("\n")) {
		if (line == "") continue;
		if (line.includes("\t") && entries.length > 0) entries[entries.length - 1].push(line);
		else entries.push([line]);
	}
	return entries;
}

export function storedOutput(store: string, key: string, hashOf: ((path: string) => string) | null = null): string {
	const manifest = manifestOf(store, key);
	const current = new HashMap<string, string>();
	for (const entry of manifestEntries(manifest)) {
		let same = true;
		for (let i = 1; same && i < entry.length; i += 1) {
			const tab = entry[i].indexOf("\t", 0);
			const path = entry[i].slice(0, tab);
			if (hashOf != null && !current.has(path)) current.set(path, hashOf(path));
			same = hashOf != null && current.get(path) == entry[i].slice(tab + 1, entry[i].length);
		}
		const out = `${store}/o/${entry[0]}`;
		if (!same || !exists(out)) continue;
		const now = nowSeconds();
		markUsed(manifest, now);
		markUsed(`${out}.u`, now);
		return out;
	}
	return "";
}

export function storeScratch(store: string, key: string): string {
	const scratch = `${store}/tmp/${hashContent(`${key}${performance.now()}`)}`;
	ensureDir(scratch);
	return scratch;
}

export function storePublish(store: string, key: string, scratch: string, digest: string, found: string[] = []): string {
	const placed = `${store}/o/${digest}`;
	ensureDir(`${store}/o`);
	if (exists(placed)) removeAll(scratch);
	else if (!rename(scratch, placed).ok) {
		removeAll(scratch);
		if (!exists(placed)) return "";
	}
	atomicWriteFile(`${placed}.u`, "u");
	ensureDir(`${store}/m`);
	const manifest = manifestOf(store, key);
	const inputs = found.join("\n");
	const kept: string[] = [found.length == 0 ? digest : `${digest}\n${inputs}`];
	if (found.length > 0) {
		for (const entry of manifestEntries(manifest)) {
			if (kept.length < MANIFEST_ENTRIES && entry.length > 1 && entry.slice(1, entry.length).join("\n") != inputs) kept.push(entry.join("\n"));
		}
	}
	atomicWriteFile(manifest, `${kept.join("\n")}\n`);
	return placed;
}

export function collectStepStore(store: string): void {
	const now = nowSeconds();
	collectStaleFlatEntries(`${store}/m`, now, [".m"]);
	collectStaleTrees(`${store}/o`, `${store}/tmp`, now);
}
