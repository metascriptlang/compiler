import {
	TransAmDb, createTransAmDb, dbSetFileText, dbParse, dbTypeCheck, dbCheckIsCurrent, dbResolveImport,
	getFileId, recordModuleImport, getDirectImports,
	dbSetGlobalImports, dbSetStdPath, cacheGet, createQueryKey, TaQueryKind,
} from "../transam/index";
import { collectImportCalls } from "../../module/loader";
import { isStdImport } from "../../module/resolver";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../../ast/node";
import { openDocuments, markDocumentOpen, markDocumentClosed } from "./handlers/shared";
import { join, normalize } from "std/fs/path";
import { mkdir, removeAll, writeFile } from "std/fs";
import { tmpDir, resolveRuntimeDir, physicalPath } from "../../utils/path";

function staticImportSources(program: Node | null): string[] {
	const sources: string[] = [];
	if (program == null || program.kind != NodeKind.Program) return sources;
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
		if (decl.kind == NodeKind.ImportDecl) sources.push((decl.data as ImportDeclData).importSource);
	}
	return sources;
}

function walkImports(db: TransAmDb, roots: string[], stdLeaves: string[] | null = null): string[] {
	const reached = new HashSet<string>();
	const universe: string[] = [];
	const pending: string[] = roots.slice();
	while (pending.length > 0) {
		const path = pending.pop()!;
		if (reached.has(path)) continue;
		reached.add(path);
		universe.push(path);
		const program = dbParse(db, path);
		const fileId = getFileId(db.fileInput, path);
		const follow = (source: string, recordEdge: boolean): void => {
			if (isStdImport(source)) {
				if (stdLeaves == null) return;
				const leaf = dbResolveImport(db, path, source);
				if (leaf != "") stdLeaves.push(leaf);
				return;
			}
			const target = dbResolveImport(db, path, source);
			if (target == "") return;
			const targetId = getFileId(db.fileInput, target);
			if (recordEdge) recordModuleImport(db.moduleDeps, fileId, targetId);
			pending.push(target);
		};
		for (const source of staticImportSources(program)) follow(source, true);
		if (program != null) {
			for (const source of collectImportCalls(program)) follow(source, false);
		}
	}
	universe.sort();
	return universe;
}

export function entryRoots(db: TransAmDb, root: string, entry: string): Result<string[], string> {
	const entryPath = dbResolveImport(db, join(root, "build.ms"), join(root, entry));
	if (entryPath == "") return Result.err(`build.ms entry '${entry}' resolves to no module under ${root}, so the project's files are unknown`);
	return Result.ok([entryPath]);
}

function projectRoots(db: TransAmDb, entryRoots: string[]): string[] {
	const roots = entryRoots.slice();
	for (const global of db.globalImports) roots.push(global.path);
	for (const open of openDocuments()) {
		if (getFileId(db.fileInput, open) >= 0) roots.push(open);
	}
	return roots;
}

export function projectUniverse(db: TransAmDb, root: string, entry: string): Result<string[], string> {
	const roots = entryRoots(db, root, entry);
	if (!roots.ok) return Result.err(roots.error);
	return Result.ok(walkImports(db, projectRoots(db, roots.value)));
}

export function completionSources(db: TransAmDb, entryRoots: string[], current: string): string[] {
	const roots = projectRoots(db, entryRoots);
	if (getFileId(db.fileInput, current) >= 0) roots.push(current);
	const leaves: string[] = [];
	const sources = walkImports(db, roots, leaves);
	const held = new HashSet<string>();
	for (const path of sources) held.add(path);
	for (const leaf of leaves) {
		if (held.has(leaf)) continue;
		held.add(leaf);
		sources.push(leaf);
	}
	sources.sort();
	return sources;
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
	const spelled = normalize(tmpDir() + "/msc-projuniverse-created-" + Date.now() + "-" + Math.random());
	assert mkdir(spelled).ok, spelled;
	const dir = physicalPath(spelled);
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

function sourcesOf(db: TransAmDb, entry: string | null, current: string, root: string = "/proj"): string {
	let roots: string[] = [];
	if (entry != null) {
		const found = entryRoots(db, root, entry);
		if (!found.ok) return found.error;
		roots = found.value;
	}
	const names: string[] = [];
	for (const path of completionSources(db, roots, current)) names.push(path.slice(root.length + 1));
	return names.join(", ");
}

test "completion sources: the entry's closure holds the unopened importers and re-exports, and the file asked joins it" {
	const db = projectDb();
	assert sourcesOf(db, "./app", "/proj/app.ms") == CLOSURE, sourcesOf(db, "./app", "/proj/app.ms");
	assert sourcesOf(db, "./app", "/proj/orphan.ms") == "app.ms, barrel.ms, direct.ms, lib.ms, orphan.ms, unrelated.ms, use.ms";
	assert sourcesOf(db, null, "/proj/orphan.ms") == "lib.ms, orphan.ms";
	assert sourcesOf(db, null, "/proj/app.ms") == CLOSURE;
}

test "completion sources: an open document is a root while it stays open, with no change to any text" {
	const db = projectDb();
	const revision = db.revision.value;
	markDocumentOpen("/proj/orphan.ms");
	const open = sourcesOf(db, null, "/proj/unrelated.ms");
	markDocumentClosed("/proj/orphan.ms");
	const closed = sourcesOf(db, null, "/proj/unrelated.ms");
	assert open == "lib.ms, orphan.ms, unrelated.ms", open;
	assert closed == "unrelated.ms", closed;
	assert db.revision.value == revision;
}

test "completion sources: an import cycle ends, a literal dynamic import counts and a computed one adds nothing" {
	const db = projectDb();
	dbSetFileText(db, "/proj/ping.ms", "import { pong } from \"./pong\";\nexport const ping = pong;");
	dbSetFileText(db, "/proj/pong.ms", "import { ping } from \"./ping\";\nexport const pong = ping;");
	assert sourcesOf(db, null, "/proj/ping.ms") == "ping.ms, pong.ms", sourcesOf(db, null, "/proj/ping.ms");
	dbSetFileText(db, "/proj/app.ms", "const name = \"./orphan\";\nconst lazy = import(\"./use\");\nconst guessed = import(name);");
	assert sourcesOf(db, null, "/proj/app.ms") == "app.ms, barrel.ms, lib.ms, use.ms", sourcesOf(db, null, "/proj/app.ms");
}

test "completion sources: a std module a file imports is a leaf and the default prelude is no root" {
	const db = projectDb();
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, "/proj/viaStd.ms", "import { readFile } from \"std/fs\";\nimport { target } from \"./lib\";\nreadFile; target;");
	const fsPath = dbResolveImport(db, "/proj/viaStd.ms", "std/fs");
	assert fsPath != "";
	const sources = completionSources(db, [], "/proj/viaStd.ms");
	let stdModules = 0;
	for (const path of sources) {
		if (path.startsWith(resolveRuntimeDir() + "/std")) stdModules++;
	}
	assert sources.includes(fsPath) && sources.includes("/proj/lib.ms");
	assert stdModules == 1, sources.join(", ");
	for (const path of completionSources(db, [], "/proj/orphan.ms")) assert !path.startsWith(resolveRuntimeDir() + "/std"), path;
}

test "completion sources: a global import is a root of every file's sources" {
	const db = projectDb();
	const unresolved = dbSetGlobalImports(db, ["/proj/unrelated"]);
	assert unresolved.length == 0, unresolved.join(", ");
	assert sourcesOf(db, null, "/proj/lib.ms") == "lib.ms, unrelated.ms", sourcesOf(db, null, "/proj/lib.ms");
}
