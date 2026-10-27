import { Symbol } from "../../ast/node";
import { CheckerContext, CheckerError, dispatchOverridesFor, dispatchEntryCount, resetDispatchRegistry, lifecycleHookOp, findModuleExports } from "../../checker/context";
import { lookupInstanceHook, resetInstantiationState } from "../../checker/instantiate";
import { symbolKey } from "../../checker/symbol";
import { unwrapRef } from "../../checker/types";
import { resolveRuntimeDir } from "../../utils/path";
import { TransAmDb, createTransAmDb, dbSetStdPath, dbSetFileText, dbParse, dbTypeCheck } from "./index";
import { recordModuleImport } from "./moduleDeps";
import { getFileId } from "./fileInput";

// A project is checked in `order`, importers after what they import; `edges` are [importer, imported].
// `classes` are [module, class], `instances` [module, exported const of a generic instance type],
// `methods` [module, class, method]. An edit is the new text of some files, as alternating path and text.
class Project {
	order: string[];
	edges: string[][];
	classes: string[][];
	methods: string[][];
	instances: string[][];
}

function exported(db: TransAmDb, path: string, name: string): Symbol {
	const entry = findModuleExports(db.exportRegistry, path);
	if (entry == null) throw new Error(`internal: ${path} has no registered exports`);
	for (const info of entry.symbols) {
		if (info.name == name) return info.sym;
	}
	throw new Error(`internal: ${path} exports no '${name}'`);
}

function newDb(project: Project): TransAmDb {
	resetInstantiationState();
	resetDispatchRegistry();
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	for (const path of project.order) dbSetFileText(db, path, "");
	for (const e of project.edges) recordModuleImport(db.moduleDeps, getFileId(db.fileInput, e[0]), getFileId(db.fileInput, e[1]));
	return db;
}

function applyEdit(db: TransAmDb, edit: string[]): void {
	for (let i = 0; i < edit.length; i += 2) dbSetFileText(db, edit[i], edit[i + 1]);
}

const HOOK_OPS = ["onDestroy", "onCopy", "onMove", "onMoved", "onClone", "onTrace"];

// What the emitters and later checks read from a checked project that adoption could leave stale: each
// module's diagnostics, the attached operations of each class, the hooks of generic instances, and the
// override order each dispatcher tries.
function snapshot(db: TransAmDb, project: Project): string {
	const lines: string[] = [];
	for (const path of project.order) dbParse(db, path);
	for (const path of project.order) {
		const ctx: CheckerContext = dbTypeCheck(db, path);
		lines.push(`${path}: ${ctx.errors.map((e: CheckerError): string => e.message).join(" | ")}`);
	}
	for (const c of project.classes) {
		const ops = unwrapRef(exported(db, c[0], c[1]).symbolType).attachedOps;
		const bound: string[] = [];
		for (let i = 0; i < ops.length; i += 1) {
			const hook = ops[i];
			bound.push(`${i}=${hook == null ? "-" : `${symbolKey(hook)}@${hook.location.line}`}`);
		}
		lines.push(`${c[1]} ops ${bound.join(",")}`);
	}
	for (const inst of project.instances) {
		const type = exported(db, inst[0], inst[1]).symbolType;
		const hooks: string[] = [];
		for (const name of HOOK_OPS) {
			const hook = lookupInstanceHook(type, lifecycleHookOp(name));
			hooks.push(`${name}=${hook == null ? "-" : `${symbolKey(hook)}@${hook.location.line}`}`);
		}
		lines.push(`${inst[1]} hooks ${hooks.join(",")}`);
	}
	for (const m of project.methods) {
		const overrides = dispatchOverridesFor(exported(db, m[0], m[1]), m[2]).map((e): string => `${e.classSym.name}.${e.methodName}`);
		lines.push(`${m[1]}.${m[2]} overridden by ${overrides.join(",")}`);
	}
	lines.push(`dispatch entries ${dispatchEntryCount()}`);
	return lines.join("\n");
}

// A kept db takes the edits in turn; then a fresh db checks the files as each edit left them.
// The two snapshots of one edit must be equal.
function parityFault(project: Project, edits: string[][]): string {
	const db = newDb(project);
	const kept: string[] = [];
	const texts: HashMap<string, string> = new HashMap<string, string>();
	const states: string[][] = [];
	for (const edit of edits) {
		applyEdit(db, edit);
		for (let i = 0; i < edit.length; i += 2) texts.set(edit[i], edit[i + 1]);
		const now: string[] = [];
		for (const path of project.order) {
			now.push(path);
			now.push(texts.get(path) ?? "");
		}
		states.push(now);
		kept.push(snapshot(db, project));
	}
	for (let i = 0; i < edits.length; i += 1) {
		const fresh = newDb(project);
		applyEdit(fresh, states[i]);
		const want = snapshot(fresh, project);
		if (want != kept[i]) return `edit ${i}: kept\n${kept[i]}\nfresh\n${want}`;
	}
	return "";
}

const RES_HOOK = 'export function onDestroy(this r: Res): void { console.log("drop " + r.id.toString()); }\n';
const RES = 'export class Res {\n\tid: int32;\n\tconstructor(id: int32) { this.id = id; }\n}\n' + RES_HOOK;
const RES_MAIN = 'import { Res } from "./res";\nexport function run(): void { const a = new Res(1); console.log(a.id.toString()); }\n';

test "a class's user hook is added, dropped and moved as a fresh check sees it" {
	const project: Project = {
		order: ["/p/res.ms", "/p/main.ms"],
		edges: [["/p/main.ms", "/p/res.ms"]],
		classes: [["/p/res.ms", "Res"]],
		methods: [],
		instances: [],
	};
	const fault = parityFault(project, [
		["/p/res.ms", RES, "/p/main.ms", RES_MAIN],
		["/p/res.ms", RES.replace(RES_HOOK, "")],
		["/p/res.ms", "\n\n" + RES.replace("drop ", "gone ")],
		["/p/res.ms", RES.replace(RES_HOOK, RES_HOOK + RES_HOOK.replace("onDestroy(this r: Res)", "onCopy(this ref r: Res, src: Res)"))],
	]);
	assert fault == "", fault;
}

const ANIMAL = 'export class Animal {\n\tname(): string { return "a"; }\n\tsound(): string { return "x"; }\n}\n';
const DOG_BODY = 'export class Dog extends Animal {\n\tsound(): string { return "woof"; }\n\tname(): string { return "d"; }\n}\n';
const COW_BODY = 'export class Cow extends Animal {\n\tsound(): string { return "moo"; }\n}\n';
const CAT_BODY = 'export class Cat extends Animal {\n\tsound(): string { return "meow"; }\n\tname(): string { return "c"; }\n}\n';
const FROM_BASE = 'import { Animal } from "./base";\n';

test "a class whose methods change dispatch order, move or leave keeps the order a fresh check gives" {
	const project: Project = {
		order: ["/d/base.ms", "/d/dog.ms", "/d/cat.ms"],
		edges: [["/d/dog.ms", "/d/base.ms"], ["/d/cat.ms", "/d/base.ms"]],
		classes: [],
		methods: [["/d/base.ms", "Animal", "sound"], ["/d/base.ms", "Animal", "name"]],
		instances: [],
	};
	const fault = parityFault(project, [
		["/d/base.ms", ANIMAL, "/d/dog.ms", FROM_BASE + DOG_BODY, "/d/cat.ms", FROM_BASE + CAT_BODY],
		["/d/base.ms", 'export class Animal {\n\tsound(): string { return "x"; }\n\tname(): string { return "a"; }\n}\n'],
		["/d/dog.ms", FROM_BASE + COW_BODY + DOG_BODY],
		["/d/cat.ms", FROM_BASE + "export const cat: int32 = 1;\n"],
		["/d/dog.ms", "\n" + FROM_BASE + 'export class Dog extends Animal {\n\tname(): string { return "d"; }\n\tsound(): string { return "woof"; }\n}\n'],
		["/d/cat.ms", FROM_BASE + CAT_BODY],
	]);
	assert fault == "", fault;
}

const BOX = 'export class Box<T> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tonDestroy(): void { console.log("one"); }\n}\n';
const BOX_USE = 'import { Box } from "./box";\nexport const held: Box<int32> = new Box<int32>(1);\nexport const text: Box<string> = new Box<string>("s");\n';

test "a generic class instantiated in another module keeps the instance hooks a fresh check gives" {
	const project: Project = {
		order: ["/g/box.ms", "/g/use.ms"],
		edges: [["/g/use.ms", "/g/box.ms"]],
		classes: [["/g/box.ms", "Box"]],
		methods: [],
		instances: [["/g/use.ms", "held"], ["/g/use.ms", "text"]],
	};
	const fault = parityFault(project, [
		["/g/box.ms", BOX, "/g/use.ms", BOX_USE],
		["/g/box.ms", BOX.replace("one", "two")],
		["/g/box.ms", BOX.replace('\tonDestroy(): void { console.log("one"); }\n', "")],
		["/g/box.ms", "\n\n" + BOX],
		["/g/box.ms", BOX.replace("\tonDestroy", '\tshow<U>(u: U): string { return "s"; }\n\tonDestroy')],
		["/g/use.ms", BOX_USE + 'export const shown: string = held.show<int32>(2);\n'],
	]);
	assert fault == "", fault;
}

const HANDLE_TYPE = 'export type Handle = distinct int32;\n';
const HANDLE_HOOK = 'export function onDestroy(this h: Handle): void { console.log("close"); }\n';
const POINT_TYPE = 'export struct Pt {\n\tx: int32;\n}\n';
const POINT_HOOK = 'export function onDestroy(this p: Pt): void { console.log("pt"); }\n';
const ALIAS = 'import { Res } from "./res";\nexport type Owned = Res;\n';

test "a distinct type, a struct and an alias of a class keep the operations a fresh check gives" {
	const project: Project = {
		order: ["/a/res.ms", "/a/handle.ms", "/a/point.ms", "/a/alias.ms"],
		edges: [["/a/alias.ms", "/a/res.ms"]],
		classes: [["/a/res.ms", "Res"], ["/a/handle.ms", "Handle"], ["/a/point.ms", "Pt"], ["/a/alias.ms", "Owned"]],
		methods: [],
		instances: [],
	};
	const fault = parityFault(project, [
		["/a/res.ms", RES, "/a/handle.ms", HANDLE_TYPE + HANDLE_HOOK, "/a/point.ms", POINT_TYPE + POINT_HOOK, "/a/alias.ms", ALIAS],
		["/a/res.ms", RES.replace(RES_HOOK, ""), "/a/handle.ms", HANDLE_TYPE, "/a/point.ms", POINT_TYPE + POINT_HOOK.replace("pt", "point")],
		["/a/res.ms", RES, "/a/handle.ms", "\n" + HANDLE_TYPE + HANDLE_HOOK, "/a/point.ms", POINT_TYPE],
	]);
	assert fault == "", fault;
}

const CELL_TYPE = 'export class Cell<T> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n}\n';
const CELL_HOOK = 'export function onDestroy<T>(this c: Cell<T>): void { console.log("cell"); }\n';
const CELL_USE = 'import { Cell } from "./cell";\nexport const ci: Cell<int32> = new Cell<int32>(1);\nexport const cs: Cell<string> = new Cell<string>("s");\n';

test "a generic class bound to a generic hook keeps the hook of each instance a fresh check gives" {
	const project: Project = {
		order: ["/c/cell.ms", "/c/use.ms"],
		edges: [["/c/use.ms", "/c/cell.ms"]],
		classes: [["/c/cell.ms", "Cell"]],
		methods: [],
		instances: [["/c/use.ms", "ci"], ["/c/use.ms", "cs"]],
	};
	const fault = parityFault(project, [
		["/c/cell.ms", CELL_TYPE + CELL_HOOK, "/c/use.ms", CELL_USE],
		["/c/cell.ms", CELL_TYPE],
		["/c/cell.ms", "\n" + CELL_TYPE + CELL_HOOK.replace("cell", "cells")],
	]);
	assert fault == "", fault;
}

test "the snapshot sees a bound hook, so the parity tests can go red" {
	const project: Project = {
		order: ["/s/cell.ms", "/s/use.ms"],
		edges: [["/s/use.ms", "/s/cell.ms"]],
		classes: [["/s/cell.ms", "Cell"]],
		methods: [],
		instances: [["/s/use.ms", "ci"]],
	};
	const db = newDb(project);
	applyEdit(db, ["/s/cell.ms", CELL_TYPE + CELL_HOOK, "/s/use.ms", CELL_USE]);
	const seen = snapshot(db, project);
	assert seen.indexOf("ops 0=-,1=onDestroy.0./s/cell.ms") >= 0, seen;
	assert seen.indexOf("hooks onDestroy=Cell_onDestroy") >= 0, seen;
}
