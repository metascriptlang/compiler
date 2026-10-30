// Early cutoff pins: what an edit of one module makes the engine recheck in the modules around it.

import { createTransAmDb, TransAmDb, dbSetFileText, dbSetStdPath, dbParse, dbTypeCheck, dbLower } from "./index";
import { TaQueryKind } from "./revision";
import { createQueryKey } from "./revision";
import { cacheGet } from "./cache";
import { getFileId } from "./fileInput";
import { recordModuleImport } from "./moduleDeps";
import { Node, NodeKind, ProgramData } from "../../ast/node";
import { CheckerContext } from "../../checker/context";
import { lookupLocal, symbolKey } from "../../checker/symbol";
import { typeDisplayName } from "../../checker/types";
import { ifaceDigest } from "./digest";
import { resetInstantiationState } from "../../checker/instantiate";
import { lowerIterInline } from "../../transform/lowering/iterInline";
import { createTransformContextWithChecker } from "../../transform/context";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { resolveRuntimeDir } from "../../utils/path";
import { macroCompileCount } from "../meta/expand";

class Count {
	n: int32;
}

function countLowering(checked: Node, ctx: CheckerContext, count: Count): Node {
	count.n += 1;
	return checked;
}

function inlineLowering(checked: Node, ctx: CheckerContext, count: Count): Node {
	count.n += 1;
	return lowerIterInline(cloneNodeKeepSem(checked), createTransformContextWithChecker(ctx));
}

// Modules are given dependencies first; each entry of `edges` is [importer, imported] as indexes into `paths`.
function openDb(paths: string[], texts: string[], edges: int32[][], stdPath: string = ""): TransAmDb {
	resetInstantiationState();
	const db = createTransAmDb(100);
	if (stdPath != "") dbSetStdPath(db, stdPath);
	for (let i = 0; i < paths.length; i++) dbSetFileText(db, paths[i], texts[i]);
	for (const e of edges) recordModuleImport(db.moduleDeps, getFileId(db.fileInput, paths[e[0]]), getFileId(db.fileInput, paths[e[1]]));
	return db;
}

function checkedAt(db: TransAmDb, path: string): int32 {
	const entry = cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, getFileId(db.fileInput, path)));
	return entry == null ? -1 : entry.computedAt;
}

// Checks every module in the given order and names the ones whose check ran again.
function check(db: TransAmDb, order: string[]): string {
	const before = order.map((p: string): int32 => checkedAt(db, p));
	for (const p of order) dbParse(db, p);
	for (const p of order) dbTypeCheck(db, p);
	const ran: string[] = [];
	for (let i = 0; i < order.length; i++) if (checkedAt(db, order[i]) != before[i]) ran.push(order[i]);
	return ran.join(",");
}

function lowerAll(db: TransAmDb, order: string[], counts: Count[]): void {
	for (let i = 0; i < order.length; i++) dbLower(db, order[i], countLowering, counts[i]);
}

const DEP = "/cut/dep.ms";
const USER = "/cut/user.ms";
const FAR = "/cut/far.ms";
const DEP_TEXT = "export function foo(): int32 { return 1; }\nexport function plain(): int32 { return 7; }";
const USER_TEXT = 'import { foo } from "./dep";\nexport const n = foo();';
const FAR_TEXT = 'import { n } from "./user";\nexport const m = n;';

function chainDb(depText: string = DEP_TEXT, userText: string = USER_TEXT): TransAmDb {
	return openDb([DEP, USER, FAR], [depText, userText, FAR_TEXT], [[1, 0], [2, 1]]);
}

const FORWARD = [DEP, USER, FAR];
const IMPORTERS_FIRST = [FAR, USER, DEP];

test "a comment edit in a dependency rechecks that module only, in either check order" {
	for (const order of [FORWARD, IMPORTERS_FIRST]) {
		const db = chainDb();
		const counts: Count[] = [{ n: 0 }, { n: 0 }, { n: 0 }];
		check(db, FORWARD);
		lowerAll(db, order, counts);
		const user = dbTypeCheck(db, USER);
		const foo = lookupLocal(user.table, "foo");
		assert foo != null && foo.location.line == 1;
		dbSetFileText(db, DEP, "// note\n" + DEP_TEXT);
		assert check(db, order) == DEP;
		lowerAll(db, order, counts);
		assert counts[0].n + counts[1].n + counts[2].n == 4, `${counts[0].n} ${counts[1].n} ${counts[2].n}`;
		const after = dbTypeCheck(db, USER);
		assert lookupLocal(after.table, "foo") == foo;
		assert foo.location.line == 2;
	}
}

test "a body edit of an exported function rechecks that module only" {
	const db = chainDb();
	const counts: Count[] = [{ n: 0 }, { n: 0 }, { n: 0 }];
	check(db, FORWARD);
	lowerAll(db, FORWARD, counts);
	dbSetFileText(db, DEP, DEP_TEXT.replace("return 1", "return 2"));
	assert check(db, FORWARD) == DEP;
	lowerAll(db, FORWARD, counts);
	assert counts[0].n == 2 && counts[1].n == 1 && counts[2].n == 1;
}

test "an edit of a module's own body leaves its importers green and lowers it again" {
	const db = chainDb();
	const counts: Count[] = [{ n: 0 }, { n: 0 }, { n: 0 }];
	check(db, FORWARD);
	lowerAll(db, FORWARD, counts);
	dbSetFileText(db, USER, USER_TEXT + "\nconst unused = 5;");
	assert check(db, FORWARD) == USER;
	lowerAll(db, FORWARD, counts);
	assert counts[0].n == 1 && counts[1].n == 2 && counts[2].n == 1;
}

test "a signature edit rechecks every importer along the chain" {
	const db = openDb(
		[DEP, USER, FAR],
		[DEP_TEXT, 'import { foo } from "./dep";\nexport function mid() { return foo(); }', 'import { mid } from "./user";\nexport const m = mid();'],
		[[1, 0], [2, 1]],
	);
	check(db, FORWARD);
	dbSetFileText(db, DEP, DEP_TEXT.replace("foo(): int32", "foo(): int64"));
	assert check(db, FORWARD) == `${DEP},${USER},${FAR}`;
	dbSetFileText(db, DEP, DEP_TEXT.replace("foo(): int32", "foo(): int64") + "\n// note");
	assert check(db, FORWARD) == DEP;
}

test "an importer rechecked after an edit below a kept module reads that module's inferred types" {
	const routine = ['import { foo } from "./dep";\nexport function mid() { return foo(); }', 'import { mid } from "./user";\nexport const m = mid();'];
	const binding = [USER_TEXT, FAR_TEXT];
	for (const texts of [routine, binding]) {
		for (const depEdit of ["// note\n" + DEP_TEXT, DEP_TEXT.replace("return 1", "return 2")]) {
			const db = openDb([DEP, USER, FAR], [DEP_TEXT, texts[0], texts[1]], [[1, 0], [2, 1]]);
			check(db, FORWARD);
			dbSetFileText(db, DEP, depEdit);
			assert check(db, FORWARD) == DEP;
			dbSetFileText(db, FAR, "\n" + texts[1]);
			assert check(db, FORWARD) == FAR;
			const m = lookupLocal(dbTypeCheck(db, FAR).table, "m");
			assert m != null && typeDisplayName(m.symbolType) == "int32", m != null ? typeDisplayName(m.symbolType) : "no m";
		}
	}
}

test "an exporter's error state reaches its importer until it is fixed" {
	const bad = "/cut/bad.ms";
	const good = 'export function foo(): int32 { return 1; }';
	const db = openDb([bad, USER], [good, USER_TEXT.replace("./dep", "./bad")], [[1, 0]]);
	check(db, [bad, USER]);
	dbSetFileText(db, bad, good.replace("return 1", 'return "x"'));
	assert check(db, [bad, USER]) == `${bad},${USER}`;
	dbSetFileText(db, bad, good);
	assert check(db, [bad, USER]) == `${bad},${USER}`;
}

const GENERIC = "export function id<T>(x: T): T { return x; }\nexport function plain(): int32 { return 1; }";
const GENERIC_USER = 'import { id } from "./dep";\nexport const a = id<int32>(1);';
const PLAIN_USER = 'import { plain } from "./dep";\nexport const p = plain();';

test "a generic body edit rechecks its instantiator and not an importer that only calls" {
	const db = openDb([DEP, USER, FAR], [GENERIC, GENERIC_USER, PLAIN_USER], [[1, 0], [2, 0]]);
	check(db, FORWARD);
	dbSetFileText(db, DEP, GENERIC.replace("return x;", "const y: T = x; return y;"));
	assert check(db, FORWARD) == `${DEP},${USER}`;
	dbSetFileText(db, DEP, "// note\n" + GENERIC.replace("return x;", "const y: T = x; return y;"));
	assert check(db, FORWARD) == DEP;
}

const TEMPLATE = "export template twice(x: int32): int32 { return x * 2; }\nexport function plain(): int32 { return 1; }";
const TEMPLATE_USER = 'import { twice } from "./dep";\nexport const t: int32 = twice(4);';

test "a template body edit rechecks its expander and not an importer that only calls" {
	const db = openDb([DEP, USER, FAR], [TEMPLATE, TEMPLATE_USER, PLAIN_USER], [[1, 0], [2, 0]]);
	check(db, FORWARD);
	dbSetFileText(db, DEP, TEMPLATE.replace("x * 2", "x * 3"));
	assert check(db, FORWARD) == `${DEP},${USER}`;
	dbSetFileText(db, DEP, "// note\n" + TEMPLATE.replace("x * 2", "x * 3"));
	assert check(db, FORWARD) == DEP;
}

const MACRO = 'import { Node } from "std/meta";\nexport macro twice(n: Node): Node {\n\treturn quote { (${n} * 2) };\n}\n';
const MACRO_USER = 'import { twice } from "./dep";\nexport const x: int32 = twice(2);\n';

test "a macro body edit rechecks its user, a comment edit does not" {
	const db = openDb([DEP, USER], [MACRO, MACRO_USER], [[1, 0]], resolveRuntimeDir() + "/std");
	assert dbTypeCheck(db, USER).errors.length == 0;
	const first = checkedAt(db, USER);
	dbSetFileText(db, DEP, "// note\n" + MACRO);
	dbParse(db, DEP);
	dbParse(db, USER);
	assert dbTypeCheck(db, USER).errors.length == 0;
	assert checkedAt(db, USER) == first;
	const built = macroCompileCount();
	dbSetFileText(db, DEP, MACRO.replace("* 2", "* 3"));
	dbParse(db, DEP);
	dbParse(db, USER);
	assert dbTypeCheck(db, USER).errors.length == 0;
	assert checkedAt(db, USER) != first;
	assert macroCompileCount() > built;
}

const GENERATOR = "export function* g(): Iterator<int32> { yield 1; }";
const GENERATOR_USER = 'import { g } from "./dep";\nlet s: int32 = 0;\nfor (const x of g()) { s += x; }';

test "an inlined generator's lowering reruns for a body edit and not for a comment edit" {
	const db = openDb([DEP, USER], [GENERATOR, GENERATOR_USER], [[1, 0]]);
	const a: Count = { n: 0 };
	const b: Count = { n: 0 };
	const lowerBoth = (): void => {
		dbParse(db, DEP);
		dbParse(db, USER);
		dbLower(db, DEP, inlineLowering, a);
		dbLower(db, USER, inlineLowering, b);
	};
	lowerBoth();
	dbSetFileText(db, DEP, "// note\n" + GENERATOR);
	lowerBoth();
	assert a.n == 2 && b.n == 1, `${a.n} ${b.n}`;
	dbSetFileText(db, DEP, GENERATOR.replace("yield 1", "yield 2"));
	lowerBoth();
	assert a.n == 3 && b.n == 2, `${a.n} ${b.n}`;
	assert (dbLower(db, USER, inlineLowering, b).data as ProgramData).programStmts[2].kind == NodeKind.BlockStmt;
}

test "a module-level extern variable re-exported by another module digests under its key" {
	const db = openDb(
		[DEP, USER],
		['export extern let errnoLike: int32;\nexport function read(): int32 { return errnoLike; }', 'export { errnoLike } from "./dep";'],
		[[1, 0]],
	);
	check(db, [DEP, USER]);
	const dep = dbTypeCheck(db, DEP);
	assert symbolKey(lookupLocal(dep.table, "errnoLike")!) == `errnoLike.0.${DEP}`;
	assert ifaceDigest(dbTypeCheck(db, USER), [ifaceDigest(dep, [])]) != 0;
}
