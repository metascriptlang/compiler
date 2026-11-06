import { Node } from "../../ast/node";
import { checkProgram } from "../../checker/checkPass";
import { parseSource } from "../../parser/statements/validation";
import {
	CheckerContext, createContext, dispatchOverridesFor, findExportedSymbol,
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
import { pickBodyCtx, preludeModuleCtx } from "../../checker/instantiate";
import { copyDispatchRegistry } from "../../checker/dispatchRegistry";

interface LazyLowering {
	runs: int32;
	dependentKept: boolean;
	durability: TaDurability;
}

function lowersAfterLazyCheck(related: boolean, evictFamily: boolean = false): LazyLowering {
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
		dispatchOverridesFor(ctx.dispatchRegistry, base.sym, "value");
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

test "another standalone check cannot poison a module's dispatch facts" {
	const parsed = parseSource(
		'export class Stray { name(): string { return "stray"; } }');
	assert parsed.ok;
	checkProgram(parsed.value);
	const db = createTransAmDb(100);
	const path = "/dispatchScope/own.ms";
	dbSetFileText(db, path, "export function value(): int32 { return 1; }");
	let problem = "";
	try {
		dbLower(db, path,
			(checked: Node, ctx: CheckerContext, arg: int32): Node => checked, 0);
	} catch (e) {
		problem = (e as Error).message;
	}
	assert problem == "", problem;
}

function checkInterleavedOwners(reverse: boolean): boolean {
	const left = createTransAmDb(100);
	const right = createTransAmDb(100);
	const first = reverse ? right : left;
	const second = reverse ? left : right;
	const basePath = "/interleavedDispatch/base.ms";
	const childPath = "/interleavedDispatch/child.ms";
	for (const db of [left, right]) {
		dbSetFileText(db, basePath,
			"export class Base { value(): int32 { return 1; } }");
		dbSetFileText(db, childPath,
			'import { Base } from "./base";\n' +
			"export class Child extends Base { override value(): int32 { return 2; } }");
		recordModuleImport(db.moduleDeps,
			getFileId(db.fileInput, childPath), getFileId(db.fileInput, basePath));
	}
	const lower = (checked: Node, ctx: CheckerContext, seen: int32[]): Node => {
		const base = findExportedSymbol(ctx.exportRegistry, basePath, "Base");
		if (base == null) throw new Error("interleaved dispatch: missing Base export");
		seen.push(dispatchOverridesFor(ctx.dispatchRegistry, base.sym, "value").length);
		return checked;
	};
	const firstSeen: int32[] = [];
	const secondSeen: int32[] = [];
	dbLower(first, basePath, lower, firstSeen);
	dbLower(second, basePath, lower, secondSeen);
	if (firstSeen.length != 1 || firstSeen[0] != 0) return false;
	if (secondSeen.length != 1 || secondSeen[0] != 0) return false;
	if (dbTypeCheck(first, childPath)!.errors.length != 0) return false;
	dbLower(second, basePath, lower, secondSeen);
	dbLower(first, basePath, lower, firstSeen);
	if (secondSeen.length != 1) return false;
	if (firstSeen.length != 2 || firstSeen[1] != 1) return false;
	if (dbTypeCheck(second, childPath)!.errors.length != 0) return false;
	dbLower(first, basePath, lower, firstSeen);
	dbLower(second, basePath, lower, secondSeen);
	return firstSeen.length == 2 && secondSeen.length == 2 && secondSeen[1] == 1;
}

test "interleaved databases keep same-path dispatch families independent" {
	assert checkInterleavedOwners(false);
}

test "dispatch ownership does not depend on database creation order" {
	assert checkInterleavedOwners(true);
}

test "a prelude body view keeps the compilation's dispatch owner" {
	for (const nested of [false, true]) {
		const prelude = createContext();
		const path = "/dispatchPrelude/body.ms";
		prelude.preludeModuleScopes.set(path, []);
		const ctx = nested ? createContext(prelude.dispatchRegistry) : prelude;
		if (nested) ctx.preludeCtx = prelude;
		const view = preludeModuleCtx(ctx, path);
		assert view != null;
		assert view.dispatchRegistry == ctx.dispatchRegistry;
	}
}

test "foreign body selection keeps a copied compilation's dispatch owner" {
	const prelude = createContext();
	const path = "/dispatchPrelude/copiedBody.ms";
	prelude.preludeModuleScopes.set(path, []);
	for (const copied of [false, true]) {
		const registry = copied ? copyDispatchRegistry(prelude.dispatchRegistry) : prelude.dispatchRegistry;
		const ctx = createContext(registry);
		ctx.preludeCtx = prelude;
		const picked = pickBodyCtx(path, ctx);
		assert picked.dispatchRegistry == ctx.dispatchRegistry;
	}
}

test "foreign body selection retains its source-prelude fallback" {
	const prelude = createContext();
	const ctx = createContext(copyDispatchRegistry(prelude.dispatchRegistry));
	ctx.preludeCtx = prelude;
	assert pickBodyCtx("/dispatchPrelude/absentBody.ms", ctx) == prelude;
}
