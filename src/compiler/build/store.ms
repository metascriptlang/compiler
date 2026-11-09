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

// A manifest is the output digest, then one `path<TAB>hash` line per input the step found while it
// ran (a depfile); the output is reused only while each of those still hashes the same.
export function storedOutput(store: string, key: string, hashOf: ((path: string) => string) | null = null): string {
	const manifest = manifestOf(store, key);
	const lines = (exists(manifest) ? (try readFile(manifest) catch "") : "").split("\n");
	const digest = lines[0];
	if (digest == "") return "";
	for (let i = 1; i < lines.length; i += 1) {
		if (lines[i] == "") continue;
		const tab = lines[i].indexOf("\t", 0);
		if (hashOf == null || tab < 0 || hashOf(lines[i].slice(0, tab)) != lines[i].slice(tab + 1, lines[i].length)) return "";
	}
	const out = `${store}/o/${digest}`;
	if (!exists(out)) return "";
	const now = nowSeconds();
	markUsed(manifest, now);
	markUsed(`${out}.u`, now);
	return out;
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
	atomicWriteFile(manifestOf(store, key), found.length == 0 ? digest : `${digest}\n${found.join("\n")}\n`);
	return placed;
}

export function collectStepStore(store: string): void {
	const now = nowSeconds();
	collectStaleFlatEntries(`${store}/m`, now, [".m"]);
	collectStaleTrees(`${store}/o`, `${store}/tmp`, now);
}
