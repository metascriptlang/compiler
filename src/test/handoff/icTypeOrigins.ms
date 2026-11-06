import { CheckerContext, Severity } from "../../checker/context";
import { resetInstantiationState } from "../../checker/instantiate";
import {
	TransAmDb, createTransAmDb, dbSetFileText, dbTypeCheck,
} from "../../compiler/transam/index";
import { getFileId } from "../../compiler/transam/fileInput";
import { recordModuleImport } from "../../compiler/transam/moduleDeps";

const ORIGIN = "/origin/a.ms";
const MIDDLE = "/origin/mid.ms";
const CLIENT = "/origin/main.ms";
const BEFORE = 'export class C { x: int32 = 1; }';
const AFTER = 'export class C { x: string = "two"; }';
const EXPORTS = 'import { C } from "./a";\n' +
	'export { C } from "./a";\n' +
	'export function mid(): string { return "ok"; }\n' +
	'export function make() { return { value: new C() }; }\n';

interface OriginObservation {
	kept: boolean;
	warm: string;
	cold: string;
}

function originDb(origin: string, client: string): TransAmDb {
	resetInstantiationState();
	const db = createTransAmDb(100);
	dbSetFileText(db, ORIGIN, origin);
	dbSetFileText(db, MIDDLE, EXPORTS);
	dbSetFileText(db, CLIENT, client);
	recordModuleImport(db.moduleDeps,
		getFileId(db.fileInput, MIDDLE), getFileId(db.fileInput, ORIGIN));
	recordModuleImport(db.moduleDeps,
		getFileId(db.fileInput, CLIENT), getFileId(db.fileInput, MIDDLE));
	return db;
}

function errors(ctx: CheckerContext): string {
	const messages: string[] = [];
	for (const e of ctx.errors) {
		if (e.severity == Severity.Error) {
			messages.push(`${e.line}:${e.column}: ${e.message}`);
		}
	}
	return messages.join("\n");
}

function checkOrigins(db: TransAmDb): CheckerContext {
	for (const path of [ORIGIN, MIDDLE]) {
		const ctx = dbTypeCheck(db, path);
		if (ctx == null || errors(ctx) != "") {
			throw new Error(`origin fixture failed checking ${path}`);
		}
	}
	const client = dbTypeCheck(db, CLIENT);
	if (client == null) throw new Error("origin fixture has no client check");
	return client;
}

function originEdit(client: string): OriginObservation {
	const db = originDb(BEFORE, client);
	const first = checkOrigins(db);
	if (errors(first) != "") throw new Error(errors(first));
	dbSetFileText(db, ORIGIN, AFTER);
	const next = checkOrigins(db);
	const warm = errors(next);
	const cold = errors(checkOrigins(originDb(AFTER, client)));
	return { kept: first == next, warm, cold };
}

test "a reexported class field reader matches fresh diagnostics" {
	const seen = originEdit('import { C } from "./mid";\nconst n: int32 = new C().x;');
	assert !seen.kept;
	assert seen.cold != "";
	assert seen.warm == seen.cold;
}

test "a foreign field behind an inferred wrapper matches fresh diagnostics" {
	const seen = originEdit('import { make } from "./mid";\nconst n: int32 = make().value.x;');
	assert !seen.kept;
	assert seen.cold != "";
	assert seen.warm == seen.cold;
}
