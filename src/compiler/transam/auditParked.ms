import {
	createTransAmDb, dbSetFileText, dbPreprocess, dbTypeCheck, taHashString,
} from "./index";
import { createCacheStore, cachePut } from "./cache";
import { createCacheEntry } from "./query";
import { tryMarkGreen, invalidateFile } from "./redGreen";
import { createFileInputStore, setFileText, getFileHash } from "./fileInput";
import { createModuleDepGraph, recordModuleImport } from "./moduleDeps";
import { createQueryKey, TaQueryKind, TaQueryState, TaDurability } from "./revision";
import { lookupLocal } from "../../checker/symbol";

test "different source texts with the same hash refresh preprocessing" {
	for (const pair of [
		["export const Az = 1;", "export const BY = 1;"],
		["export const value = \"Az\";", "export const value = \"BY\";"],
	]) {
		assert pair[0] != pair[1];
		assert taHashString(pair[0]) == taHashString(pair[1]);
		const db = createTransAmDb(100);
		dbSetFileText(db, "/collision/source.ms", pair[0]);
		assert dbPreprocess(db, "/collision/source.ms") == pair[0];
		assert dbSetFileText(db, "/collision/source.ms", pair[1]);
		assert dbPreprocess(db, "/collision/source.ms") == pair[1];
	}
}

test "renaming an export to a same-hash name refreshes its checked symbols" {
	for (const pair of [["Az", "BY"], ["Cx", "DW"]]) {
		const db = createTransAmDb(100);
		const path = "/collision/export.ms";
		dbSetFileText(db, path, `export const ${pair[0]} = 1;`);
		assert lookupLocal(dbTypeCheck(db, path).table, pair[0]) != null;
		dbSetFileText(db, path, `export const ${pair[1]} = 1;`);
		const ctx = dbTypeCheck(db, path);
		assert lookupLocal(ctx.table, pair[1]) != null;
		assert lookupLocal(ctx.table, pair[0]) == null;
	}
}

test "a changed high-durability input invalidates its unchecked consumers" {
	for (const durability of [TaDurability.Low, TaDurability.High]) {
		const cache = createCacheStore(10);
		const input = createFileInputStore();
		const graph = createModuleDepGraph();
		setFileText(input, "/durability/dep.ms", "export const value = 1;");
		const depKey = createQueryKey(TaQueryKind.Parse, 0);
		const dep = createCacheEntry(depKey);
		dep.computedAt = 1;
		dep.verifiedAt = 1;
		dep.outputHash = 42;
		dep.state = TaQueryState.Green;
		dep.durability = durability;
		dep.dependencies = [{
			depKey: createQueryKey(TaQueryKind.FileText, 0),
			expectedHash: getFileHash(input, 0)!,
		}];
		cachePut(cache, dep);
		const userKey = createQueryKey(TaQueryKind.TypeCheck, 1);
		const user = createCacheEntry(userKey);
		user.computedAt = 1;
		user.verifiedAt = 1;
		user.state = TaQueryState.Green;
		user.dependencies = [{ depKey, expectedHash: 42 }];
		cachePut(cache, user);
		recordModuleImport(graph, 1, 0);
		setFileText(input, "/durability/dep.ms", "export const value = 2;");
		invalidateFile(cache, graph, 0);
		assert !tryMarkGreen(cache, input, userKey, 2);
	}
}
