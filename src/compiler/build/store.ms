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

export function storedOutput(store: string, key: string): string {
	const manifest = manifestOf(store, key);
	const digest = exists(manifest) ? (try readFile(manifest) catch "") : "";
	if (digest == "") return "";
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

export function storePublish(store: string, key: string, scratch: string, digest: string): string {
	const placed = `${store}/o/${digest}`;
	ensureDir(`${store}/o`);
	if (exists(placed)) removeAll(scratch);
	else if (!rename(scratch, placed).ok) {
		removeAll(scratch);
		if (!exists(placed)) return "";
	}
	atomicWriteFile(`${placed}.u`, "u");
	ensureDir(`${store}/m`);
	atomicWriteFile(manifestOf(store, key), digest);
	return placed;
}

export function collectStepStore(store: string): void {
	const now = nowSeconds();
	collectStaleFlatEntries(`${store}/m`, now, [".m"]);
	collectStaleTrees(`${store}/o`, `${store}/tmp`, now);
}
