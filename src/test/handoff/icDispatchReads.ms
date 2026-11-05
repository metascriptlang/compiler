import { Node } from "../../ast/node";
import {
	CheckerContext, dispatchOverridesFor, findExportedSymbol,
	resetDispatchRegistry,
} from "../../checker/context";
import {
	createTransAmDb, dbSetFileText, dbTypeCheck, dbLower,
} from "../../compiler/transam/index";
import { getFileId, setFileDurability } from "../../compiler/transam/fileInput";
import { cacheGet, cachePut, cacheRemove } from "../../compiler/transam/cache";
import { createCacheEntry } from "../../compiler/transam/query";
import {
	TaDurability, TaQueryKind, TaQueryState, createQueryKey,
} from "../../compiler/transam/revision";
import { recordModuleImport } from "../../compiler/transam/moduleDeps";

interface LazyLowering {
	runs: int32;
	dependentKept: boolean;
	durability: TaDurability;
}

function lowersAfterLazyCheck(related: boolean, evictFamily: boolean = false): LazyLowering {
	resetDispatchRegistry();
	const db = createTransAmDb(100);
	const root = related ? "/lazyRelated" : "/lazyOther";
	const basePath = `${root}/base.ms`;
	const childPath = `${root}/child.ms`;
	dbSetFileText(db, basePath,
		"export class Base { value(): int32 { return 1; } }\n" +
		"export class Other { value(): int32 { return 2; } }\n");
	const parent = related ? "Base" : "Other";
	dbSetFileText(db, childPath,
		`import { ${parent} } from "./base";\n` +
		`export class Child extends ${parent} {\n` +
		"override value(): int32 { return 3; }\n}\n");
	recordModuleImport(db.moduleDeps,
		getFileId(db.fileInput, childPath), getFileId(db.fileInput, basePath));
	const baseId = getFileId(db.fileInput, basePath);
	setFileDurability(db.fileInput, baseId, TaDurability.High, db.revision.value);
	if (dbTypeCheck(db, basePath)!.errors.length != 0) {
		throw new Error(`${root}: base check failed`);
	}
	const count: int32[] = [0];
	const lower = (checked: Node, ctx: CheckerContext, seen: int32[]): Node => {
		const base = findExportedSymbol(db.exportRegistry, basePath, "Base");
		if (base == null) throw new Error(`${root}: missing Base export`);
		dispatchOverridesFor(base.sym, "value");
		seen[0] += 1;
		return checked;
	};
	dbLower(db, basePath, lower, count);
	if (count[0] != 1) throw new Error(`${root}: initial lowering did not run`);
	const lowerKey = createQueryKey(TaQueryKind.Lower, baseId);
	const lowerEntry = cacheGet(db.cache, lowerKey)!;
	const durability = lowerEntry.durability;
	if (evictFamily) {
		for (const dep of lowerEntry.dependencies) {
			if (dep.queryKind == TaQueryKind.Dispatch) cacheRemove(db.cache, dep);
		}
	}
	const outerKey = createQueryKey(TaQueryKind.Transform, baseId);
	const outer = createCacheEntry(outerKey);
	outer.state = TaQueryState.Green;
	outer.verifiedAt = db.revision.value;
	outer.dependencies = [lowerKey];
	cachePut(db.cache, outer);
	const revision = db.revision.value;
	if (dbTypeCheck(db, childPath)!.errors.length != 0) {
		throw new Error(`${root}: child check failed`);
	}
	if (db.revision.value != revision) {
		throw new Error(`${root}: checking advanced the input revision`);
	}
	dbLower(db, basePath, lower, count);
	resetDispatchRegistry();
	return {
		runs: count[0],
		dependentKept: cacheGet(db.cache, outerKey) != null,
		durability,
	};
}

test "a lazy override invalidates its family within the same revision" {
	assert lowersAfterLazyCheck(true).runs == 2;
}

test "a changed family invalidates a cached reader of its lowering" {
	assert !lowersAfterLazyCheck(true).dependentKept;
}

test "a lazy override of another family preserves cached readers" {
	const seen = lowersAfterLazyCheck(false);
	assert seen.runs == 1;
	assert seen.dependentKept;
}

test "an evicted family memo cannot hide a same-revision change" {
	assert lowersAfterLazyCheck(true, true).runs == 2;
	assert lowersAfterLazyCheck(false, true).runs == 1;
}

test "a high-durability module that reads dispatch has low durability" {
	assert lowersAfterLazyCheck(false).durability == TaDurability.Low;
}
