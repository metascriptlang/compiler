import {
	TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, dbCheckIsCurrent, dbResolveImport, dbForgetAllTypeChecks,
	dbGetFileCount, getFileId, recordModuleImport, getDirectImports,
	dbSetGlobalImports, cacheGet, createQueryKey, TaQueryKind,
} from "../transam/index";
import { collectImportCalls } from "../../module/loader";
import { isStdImport } from "../../module/resolver";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../../ast/node";
import { openDocuments, markDocumentOpen, markDocumentClosed } from "./handlers/shared";
import { join, normalize } from "std/fs/path";
import { mkdir, removeAll, writeFile } from "std/fs";
import { tmpDir } from "../../utils/path";

function staticImportSources(program: Node): string[] {
	const sources: string[] = [];
	if (program == null || program.kind != NodeKind.Program) return sources;
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
		if (decl.kind == NodeKind.ImportDecl) sources.push((decl.data as ImportDeclData).importSource);
	}
	return sources;
}

function walkImports(db: TransAmDb, roots: string[]): string[] {
	const knownBefore = dbGetFileCount(db);
	const reached = new HashSet<string>();
	const universe: string[] = [];
	const pending: string[] = roots.slice();
	let rebound = false;
	while (pending.length > 0) {
		const path = pending.pop()!;
		if (reached.has(path)) continue;
		reached.add(path);
		universe.push(path);
		const program = dbParse(db, path);
		const fileId = getFileId(db.fileInput, path);
		const follow = (source: string, recordEdge: boolean): void => {
			if (isStdImport(source)) return;
			const target = dbResolveImport(db, path, source);
			if (target == "") return;
			const targetId = getFileId(db.fileInput, target);
			if (recordEdge) recordModuleImport(db.moduleDeps, fileId, targetId);
			if (fileId < knownBefore && targetId >= knownBefore) rebound = true;
			pending.push(target);
		};
		for (const source of staticImportSources(program)) follow(source, true);
		if (program != null) {
			for (const source of collectImportCalls(program)) follow(source, false);
		}
	}
	if (rebound) dbForgetAllTypeChecks(db);
	universe.sort();
	return universe;
}

export function projectUniverse(db: TransAmDb, root: string, entry: string): Result<string[], string> {
	const entryPath = dbResolveImport(db, join(root, "build.ms"), join(root, entry));
	if (entryPath == "") return Result.err(`build.ms entry '${entry}' resolves to no module under ${root}, so the project's files are unknown`);
	const roots = [entryPath];
	for (const global of db.globalImports) roots.push(global.path);
	for (const open of openDocuments()) {
		if (getFileId(db.fileInput, open) >= 0) roots.push(open);
	}
	return Result.ok(walkImports(db, roots));
}

const LIB = "export function target(): int32 { return 1; }";
const APP = "import { target as t } from \"./use\";\nimport { target } from \"./direct\";\nimport { target as other } from \"./unrelated\";\nt(); target(); other();";

function projectDb(): TransAmDb {
	const db = createTransAmDb(100);
	const files = [
		["lib.ms", LIB],
		["barrel.ms", "export { target } from \"./lib\";"],
		["use.ms", "import { target as t } from \"./barrel\";\nexport const target = t;"],
		["direct.ms", "import { target } from \"./lib\";\nexport { target };"],
		["unrelated.ms", "export function target(): int32 { return 2; }"],
		["orphan.ms", "import { target } from \"./lib\";\ntarget();"],
		["app.ms", APP],
	];
	for (const f of files) dbSetFileText(db, "/proj/" + f[0], f[1]);
	return db;
}

function universeOf(db: TransAmDb, entry: string, root: string = "/proj"): string {
	const found = projectUniverse(db, root, entry);
	if (!found.ok) return found.error;
	const names: string[] = [];
	for (const path of found.value) names.push(path.slice(root.length + 1));
	return names.join(", ");
}

const CLOSURE = "app.ms, barrel.ms, direct.ms, lib.ms, unrelated.ms, use.ms";

test "the universe is the entry's import closure, re-exports included, whichever file is open" {
	const db = projectDb();
	assert universeOf(db, "./app") == CLOSURE, universeOf(db, "./app");
	markDocumentOpen("/proj/lib.ms");
	const withLibOpen = universeOf(db, "./app");
	markDocumentClosed("/proj/lib.ms");
	assert withLibOpen == CLOSURE, withLibOpen;
	assert universeOf(db, "./app.ms") == CLOSURE;
	assert universeOf(db, "app.ms") == CLOSURE;
	assert universeOf(db, "/proj/app.ms") == CLOSURE;
}

test "an open document outside the entry's closure is a root while it stays open" {
	const db = projectDb();
	markDocumentOpen("/proj/orphan.ms");
	const open = universeOf(db, "./app");
	markDocumentClosed("/proj/orphan.ms");
	assert open == "app.ms, barrel.ms, direct.ms, lib.ms, orphan.ms, unrelated.ms, use.ms", open;
	assert universeOf(db, "./app") == CLOSURE;
}

test "an entry edit that drops an import drops the importer, and undoing it restores the importer" {
	const db = projectDb();
	assert universeOf(db, "./app") == CLOSURE;
	dbSetFileText(db, "/proj/app.ms", "import { target } from \"./direct\";\ntarget();");
	assert universeOf(db, "./app") == "app.ms, direct.ms, lib.ms", universeOf(db, "./app");
	dbSetFileText(db, "/proj/app.ms", APP);
	assert universeOf(db, "./app") == CLOSURE;
}

test "a literal dynamic import is in the universe and a computed one adds nothing" {
	const db = projectDb();
	dbSetFileText(db, "/proj/app.ms", "const name = \"./orphan\";\nconst lazy = import(\"./use\");\nconst guessed = import(name);");
	assert universeOf(db, "./app") == "app.ms, barrel.ms, lib.ms, use.ms", universeOf(db, "./app");
}

test "implicit global imports belong to the universe without eager type checking" {
	const db = projectDb();
	dbSetFileText(db, "/proj/implicit.ms", "export const implicitValue = 1;");
	assert dbSetGlobalImports(db, ["/proj/implicit.ms"]).length == 0;
	const scope = projectUniverse(db, "/proj", "app.ms");
	assert scope.ok;
	assert universeOf(db, "app.ms") == "app.ms, barrel.ms, direct.ms, implicit.ms, lib.ms, unrelated.ms, use.ms";
	for (const path of scope.value) {
		assert cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, getFileId(db.fileInput, path))) == null;
	}
}

test "an empty entry drops the formerly reachable unopened files" {
	const db = projectDb();
	assert universeOf(db, "app.ms") == CLOSURE;
	dbSetFileText(db, "/proj/app.ms", "");
	assert universeOf(db, "app.ms") == "app.ms";
}

test "an import cycle is walked once" {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/proj/a.ms", "import { b } from \"./b\";\nexport const a = 1;");
	dbSetFileText(db, "/proj/b.ms", "import { a } from \"./a\";\nexport const b = 2;");
	assert universeOf(db, "./a") == "a.ms, b.ms";
}

test "the walk adds import edges and keeps the ones a check recorded" {
	const db = projectDb();
	const appId = getFileId(db.fileInput, "/proj/app.ms");
	const orphanId = getFileId(db.fileInput, "/proj/orphan.ms");
	recordModuleImport(db.moduleDeps, appId, orphanId);
	assert universeOf(db, "./app") == CLOSURE;
	assert getDirectImports(db.moduleDeps, appId).indexOf(orphanId) >= 0;
	assert getDirectImports(db.moduleDeps, appId).indexOf(getFileId(db.fileInput, "/proj/use.ms")) >= 0;
}

test "an entry that resolves to no module is an error naming it" {
	const db = projectDb();
	const found = projectUniverse(db, "/proj", "./missing");
	assert !found.ok;
	assert found.error.indexOf("build.ms entry './missing'") == 0, found.error;
}

test "a module created after its importer was checked makes that check stale" {
	const dir = normalize(tmpDir() + "/msc-projuniverse-created-" + Date.now() + "-" + Math.random());
	assert mkdir(dir).ok, dir;
	try {
		const db = createTransAmDb(100);
		dbSetFileText(db, dir + "/app.ms", "import { later } from \"./later\";\nlater;");
		assert universeOf(db, "./app", dir) == "app.ms";
		dbTypeCheck(db, dir + "/app.ms");
		assert dbCheckIsCurrent(db, dir + "/app.ms");
		assert writeFile(dir + "/later.ms", "export const later = 1;").ok, dir;
		assert universeOf(db, "./app", dir) == "app.ms, later.ms";
		assert !dbCheckIsCurrent(db, dir + "/app.ms");
	} finally {
		removeAll(dir);
	}
}
