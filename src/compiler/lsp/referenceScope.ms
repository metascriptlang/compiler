import { TransAmDb, createTransAmDb, dbSetFileText, dbTypeCheck, TaQueryKind } from "../transam/index";
import { handleReferences, handleRename } from "./handlers/queries";

const FILES = ["lib", "a", "barrel", "viaBarrel", "unrelated", "lookalike"];

function scopeDb(): TransAmDb {
	const db = createTransAmDb(100);
	dbSetFileText(db, "/scope/lib.ms", "export function f(): int32 { return 1; }");
	dbSetFileText(db, "/scope/a.ms", "import { f } from \"./lib\";\nexport function h(p: int32): int32 { return p + f(); }");
	dbSetFileText(db, "/scope/barrel.ms", "export { f } from \"./lib\";");
	dbSetFileText(db, "/scope/viaBarrel.ms", "import { f as g } from \"./barrel\";\nexport const v = g();");
	dbSetFileText(db, "/scope/unrelated.ms", "export const u = 2;");
	dbSetFileText(db, "/scope/lookalike.ms", "export const fx = 3;\nexport const of = 4;");
	return db;
}

function universe(): string[] {
	return FILES.map((name: string): string => "/scope/" + name + ".ms");
}

function checksDuring(db: TransAmDb, run: () => string): int32 {
	const before = db.cache.recomputed[TaQueryKind.TypeCheck as int32];
	run();
	return db.cache.recomputed[TaQueryKind.TypeCheck as int32] - before;
}

function params(file: string, line: int32, character: int32): string {
	return `{"textDocument":{"uri":"file:///scope/${file}.ms"},"position":{"line":${line},"character":${character}},"context":{"includeDeclaration":true},"newName":"renamed"}`;
}

test "references to a parameter check no other module" {
	const db = scopeDb();
	dbTypeCheck(db, "/scope/a.ms");
	const at = params("a", 1, 18);
	let found = "";
	const checks = checksDuring(db, (): string => { found = handleReferences("1", at, db, universe()); return found; });
	assert checks == 0, "" + checks;
	assert found.indexOf("a.ms") >= 0, found;
}

test "references to an exported symbol check only the modules spelling its name, and still reach an alias through a re-export" {
	const db = scopeDb();
	dbTypeCheck(db, "/scope/lib.ms");
	const at = params("lib", 0, 16);
	let found = "";
	const checks = checksDuring(db, (): string => { found = handleReferences("1", at, db, universe()); return found; });
	assert checks == 3, "" + checks;
	assert found.indexOf("viaBarrel.ms") >= 0 && found.indexOf("a.ms") >= 0 && found.indexOf("barrel.ms") >= 0, found;
	assert found.indexOf("unrelated.ms") < 0 && found.indexOf("lookalike.ms") < 0, found;
}

test "rename of an exported symbol checks only the modules spelling its name, and a local one checks none" {
	const db = scopeDb();
	dbTypeCheck(db, "/scope/lib.ms");
	let found = "";
	const exported = checksDuring(db, (): string => { found = handleRename("1", params("lib", 0, 16), db, universe()); return found; });
	assert exported == 3, "" + exported;
	assert found.indexOf("a.ms") >= 0 && found.indexOf("barrel.ms") >= 0, found;
	dbTypeCheck(db, "/scope/a.ms");
	const local = checksDuring(db, (): string => handleRename("2", params("a", 1, 18), db, universe()));
	assert local == 0, "" + local;
}
