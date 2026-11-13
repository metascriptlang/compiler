import {
	Node,
	NodeKind,
	ProgramData,
	ExportDeclData,
	DecoratedDeclData,
	VariableDeclData,
	DestructuringDeclData,
	ClassDeclData,
	PropertyDeclData,
	FunctionDeclData,
	BlockStmtData,
	ArrayPatternData,
	ObjectPatternData,
	ObjectPatternPropData,
	SpreadExprData,
	Symbol,
	Type,
	SourceLocation,
	SymbolKind,
	SymbolFlag,
	DeclKind,
	createNodeAt,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { hasFlag } from "../../checker/symbol";
import { routineBody } from "../../checker/effects";
import {
	makeAssign,
	makeExprStmt,
	makeIdentResolved,
	makeVarDecl,
} from "../../transform/util";
import { staticFieldAssignment } from "../../transform/lowering/staticLower";

export enum InitShape {
	Variable,
	StaticField,
	Destructuring,
}

export interface InitUnit {
	shape: InitShape;
	modulePath: string;
	ordinal: int32;
	stmt: Node;
	decl: Node;
	owner: Node | null;
	syms: Symbol[];
	inWasm: boolean;
	jsReads: Symbol[];
}

export interface InitThunk {
	unit: InitUnit;
	name: string;
	returns: boolean;
	getters: int32[];
}

function declOf(stmt: Node): Node {
	let decl = stmt;
	while (decl != null) {
		if (decl.kind == NodeKind.DecoratedDecl) {
			decl = (decl.data as DecoratedDeclData).decoratedNode;
		} else if (decl.kind == NodeKind.ExportDecl) {
			decl = (decl.data as ExportDeclData).exportedDecl;
		} else {
			return decl;
		}
	}
	return stmt;
}

function boundSyms(pattern: Node | null, out: Symbol[]): void {
	if (pattern == null) return;
	match (pattern.kind) {
		NodeKind.Identifier => {
			if (pattern.resolvedSym != null) out.push(pattern.resolvedSym!);
		},
		NodeKind.SpreadExpr => boundSyms((pattern.data as SpreadExprData).spreadArg, out),
		NodeKind.ArrayPattern => {
			for (const e of (pattern.data as ArrayPatternData).patternElements) {
				boundSyms(e, out);
			}
		},
		NodeKind.ObjectPattern => {
			for (const p of (pattern.data as ObjectPatternData).patternProps) {
				boundSyms(p, out);
			}
		},
		NodeKind.ObjectPatternProp => {
			boundSyms((pattern.data as ObjectPatternPropData).propAlias, out);
		},
		_ => {},
	}
}

function unitOf(
	shape: InitShape,
	modulePath: string,
	stmt: Node,
	decl: Node,
	owner: Node | null,
	syms: Symbol[],
	units: InitUnit[],
): void {
	units.push({
		shape,
		modulePath,
		ordinal: units.length as int32,
		stmt,
		decl,
		owner,
		syms,
		inWasm: false,
		jsReads: [],
	});
}

function bareMember(member: Node): Node {
	return member.kind == NodeKind.DecoratedDecl
		? (member.data as DecoratedDeclData).decoratedNode
		: member;
}

function isStaticField(member: Node): boolean {
	if (member.kind != NodeKind.PropertyDecl) return false;
	const d = member.data as PropertyDeclData;
	return d.propIsStatic && d.propInitializer != null && member.resolvedSym != null;
}

export function initUnits(program: Node, modulePath: string): InitUnit[] {
	const units: InitUnit[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOf(stmt);
		match (decl.kind) {
			NodeKind.VariableDecl => {
				const d = decl.data as VariableDeclData;
				if (d.initializer != null && decl.resolvedSym != null) {
					const syms = [decl.resolvedSym!];
					unitOf(InitShape.Variable, modulePath, stmt, decl, null, syms, units);
				}
			},
			NodeKind.DestructuringDecl => {
				const syms: Symbol[] = [];
				boundSyms((decl.data as DestructuringDeclData).destrPattern, syms);
				const shape = InitShape.Destructuring;
				unitOf(shape, modulePath, stmt, decl, null, syms, units);
			},
			NodeKind.ClassDecl => {
				for (const m of (decl.data as ClassDeclData).classBody) {
					const member = bareMember(m);
					if (!isStaticField(member)) continue;
					const syms = [member.resolvedSym!];
					const shape = InitShape.StaticField;
					unitOf(shape, modulePath, stmt, member, decl, syms, units);
				}
			},
			_ => {},
		}
	}
	return units;
}

export function initializerOf(u: InitUnit): Node | null {
	return match (u.shape) {
		InitShape.Variable => (u.decl.data as VariableDeclData).initializer,
		InitShape.StaticField => (u.decl.data as PropertyDeclData).propInitializer,
		InitShape.Destructuring => (u.decl.data as DestructuringDeclData).destrInit,
	};
}

function readsState(sym: Symbol): boolean {
	return match (sym.symbolKind) {
		SymbolKind.Variable | SymbolKind.Property | SymbolKind.Parameter
			| SymbolKind.Temp | SymbolKind.Function | SymbolKind.Method => true,
		_ => false,
	};
}

export function runsCode(node: Node | null): boolean {
	if (node == null) return false;
	const k = node.kind;
	if (k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr) return false;
	if (k == NodeKind.CallExpr || k == NodeKind.NewExpr) return true;
	if (k == NodeKind.AwaitExpr || k == NodeKind.YieldExpr) return true;
	if (node.resolvedSym != null && readsState(node.resolvedSym!)) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found) found = runsCode(child);
	});
	return found;
}

function unitRunsCode(u: InitUnit): boolean {
	if (u.shape != InitShape.Destructuring) return runsCode(initializerOf(u));
	return runsCode(u.decl);
}

export function thunkName(u: InitUnit): string {
	return `msbInit${u.ordinal}`;
}

export function getterName(u: InitUnit, at: int32): string {
	return `msbInit${u.ordinal}_${at}`;
}

interface Reach {
	seen: HashSet<Node>;
	visit: (node: Node) => void;
}

function reachClass(decl: Node, r: Reach): void {
	if (r.seen.has(decl)) return;
	r.seen.add(decl);
	for (const m of (decl.data as ClassDeclData).classBody) {
		const member = bareMember(m);
		if (isStaticField(member)) continue;
		r.seen.add(member);
		r.visit(member);
	}
}

function reachSym(sym: Symbol, r: Reach): void {
	if (sym.ctorOwner != null && sym.ctorOwner!.declNode != null) {
		reachDecl(sym.ctorOwner!.declNode, r);
	}
	reachDecl(sym.declNode, r);
	for (const o of sym.overloads) reachDecl(o.declNode, r);
}

function reachDecl(decl: Node | null, r: Reach): void {
	if (decl == null || r.seen.has(decl)) return;
	match (decl.kind) {
		NodeKind.ClassDecl => reachClass(decl, r),
		NodeKind.FunctionDecl | NodeKind.MethodDecl | NodeKind.ConstructorDecl => {
			r.seen.add(decl);
			const body = routineBody(decl);
			if (body != null) r.visit(body);
		},
		_ => {},
	}
}

export function planInitThunks(
	programs: Node[],
	paths: string[],
	roots: Node[],
): InitThunk[] {
	const units: InitUnit[] = [];
	const unitBySym = new HashMap<Symbol, InitUnit>();
	const perModule: InitUnit[][] = [];
	for (let i = 0; i < programs.length; i += 1) {
		const own = initUnits(programs[i], paths[i]);
		perModule.push(own);
		for (const u of own) {
			units.push(u);
			if (!unitRunsCode(u)) continue;
			for (const s of u.syms) unitBySym.set(s, u);
		}
	}
	const unitAt = (sym: Symbol): InitUnit | null => {
		return unitBySym.has(sym) ? unitBySym.get(sym)! : null;
	};

	const wasm: Reach = { seen: new HashSet<Node>(), visit: (n: Node): void => {} };
	const visitWasm = (node: Node): void => {
		const sym = node.resolvedSym;
		if (sym != null) {
			const u = unitAt(sym!);
			if (u != null && !u!.inWasm) {
				u!.inWasm = true;
				visitWasm(u!.shape == InitShape.Destructuring ? u!.decl : initializerOf(u!)!);
			}
			reachSym(sym!, wasm);
		}
		forEachChild(node, visitWasm);
	};
	wasm.visit = visitWasm;
	for (const root of roots) {
		if (root.kind == NodeKind.ClassDecl) reachClass(root, wasm);
		else reachDecl(root, wasm);
	}

	const js: Reach = { seen: new HashSet<Node>(), visit: (n: Node): void => {} };
	const visitJs = (node: Node): void => {
		const sym = node.resolvedSym;
		if (sym != null) {
			const u = unitAt(sym!);
			if (u != null && u!.inWasm && !u!.jsReads.includes(sym!)) {
				u!.jsReads.push(sym!);
			}
			if (!hasFlag(sym!, SymbolFlag.Wasm)) reachSym(sym!, js);
		}
		forEachChild(node, visitJs);
	};
	js.visit = visitJs;
	const inWasm = (u: InitUnit | null): boolean => u != null && u!.inWasm;
	for (let i = 0; i < programs.length; i += 1) {
		const own = perModule[i];
		const unitFor = (decl: Node): InitUnit | null => {
			const found = own.find((u) => u.decl == decl);
			return found ?? null;
		};
		for (const stmt of (programs[i].data as ProgramData).programStmts) {
			const decl = declOf(stmt);
			match (decl.kind) {
				NodeKind.FunctionDecl => {
					if (!wasm.seen.has(decl) && !hasFlag(decl.resolvedSym!, SymbolFlag.Wasm)) {
						reachDecl(decl, js);
					}
				},
				NodeKind.ClassDecl => {
					for (const m of (decl.data as ClassDeclData).classBody) {
						const member = bareMember(m);
						if (isStaticField(member)) {
							if (!inWasm(unitFor(member))) {
								visitJs((member.data as PropertyDeclData).propInitializer);
							}
						} else if (!wasm.seen.has(member)) {
							js.seen.add(member);
							visitJs(member);
						}
					}
				},
				NodeKind.VariableDecl | NodeKind.DestructuringDecl => {
					if (!inWasm(unitFor(decl))) visitJs(stmt);
				},
				_ => visitJs(stmt),
			}
		}
	}

	const thunks: InitThunk[] = [];
	for (const u of units) {
		if (!u.inWasm) continue;
		const thunk: InitThunk = {
			unit: u,
			name: thunkName(u),
			returns: false,
			getters: [],
		};
		if (u.shape == InitShape.Destructuring) {
			for (let at = 0; at < u.syms.length; at += 1) {
				if (u.jsReads.includes(u.syms[at])) thunk.getters.push(at);
			}
		} else {
			thunk.returns = u.jsReads.length > 0;
		}
		thunks.push(thunk);
	}
	return thunks;
}

function targetsOf(u: InitUnit): string[] {
	if (u.shape != InitShape.StaticField) return u.syms.map((s) => s.name);
	const owner = (u.owner!.data as ClassDeclData).className;
	return [`${owner}.${(u.decl.data as PropertyDeclData).propName}`];
}

export interface ThunkLine {
	modulePath: string;
	ordinal: int32;
	targets: string[];
	returns: boolean;
	getters: int32[];
}

export function lineOf(t: InitThunk): ThunkLine {
	return {
		modulePath: t.unit.modulePath,
		ordinal: t.unit.ordinal,
		targets: targetsOf(t.unit),
		returns: t.returns,
		getters: t.getters,
	};
}

export function thunkSource(line: ThunkLine): string {
	const name = `msbInit${line.ordinal}`;
	const lines = ["", "@wasm"];
	if (line.returns) {
		lines.push(`export function ${name}() {`);
		lines.push(`\treturn ${line.targets[0]};`);
		lines.push("}");
	} else {
		lines.push(`export function ${name}(): void {}`);
	}
	for (const at of line.getters) {
		lines.push("@wasm");
		lines.push(`export function ${name}_${at}() {`);
		lines.push(`\treturn ${line.targets[at]};`);
		lines.push("}");
	}
	return lines.join("\n") + "\n";
}

export function encodeThunks(lines: ThunkLine[]): string {
	let text = "";
	for (const l of lines) {
		const fields = [
			l.modulePath,
			`${l.ordinal}`,
			l.targets.join(","),
			l.returns ? "1" : "0",
			l.getters.map((g) => `${g}`).join(","),
		];
		text += fields.join("\t") + "\n";
	}
	return text;
}

function indexOf(text: string): int32 {
	const n = text.parseInt();
	return n >= 0 && n.toString() == text ? n as int32 : -1;
}

export function decodeThunks(text: string): Result<ThunkLine[], string> {
	const lines: ThunkLine[] = [];
	for (const line of text.split("\n")) {
		if (line == "") continue;
		const f = line.split("\t");
		const ordinal = f.length == 5 ? indexOf(f[1]) : -1;
		const getters = f.length == 5 && f[4] != "" ? f[4].split(",").map(indexOf) : [];
		if (ordinal < 0 || getters.some((g) => g < 0)) {
			return Result.err(`internal: malformed wasm init line '${line}'`);
		}
		lines.push({
			modulePath: f[0],
			ordinal,
			targets: f[2].split(","),
			returns: f[3] == "1",
			getters,
		});
	}
	return Result.ok(lines);
}

export function thunkOfLine(units: InitUnit[], line: ThunkLine): Result<InitThunk, string> {
	const u = line.ordinal < units.length ? units[line.ordinal] : null;
	const found = u == null ? "" : targetsOf(u!).join(",");
	const planned = line.targets.join(",");
	if (u == null || found != planned) {
		return Result.err(
			`internal: the wasm half numbers '${line.modulePath}' initializer `
				+ `${line.ordinal} as '${found}', the JS build as '${planned}'`,
		);
	}
	return Result.ok({
		unit: u!,
		name: thunkName(u!),
		returns: line.returns,
		getters: line.getters,
	});
}

function exportedFunctionNamed(program: Node, name: string): Node | null {
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOf(stmt);
		if (decl.kind != NodeKind.FunctionDecl) continue;
		if ((decl.data as FunctionDeclData).fnName == name) return decl;
	}
	return null;
}

function bareDecls(u: InitUnit, kind: DeclKind, inits: (Node | null)[]): Node[] {
	const loc = u.decl.location;
	const decls: Node[] = [];
	for (let i = 0; i < u.syms.length; i += 1) {
		const sym = u.syms[i];
		const init = i < inits.length ? inits[i] : null;
		const v = makeVarDecl(sym.name, init as unknown as Node, kind, loc);
		v.resolvedSym = sym;
		v.nodeType = sym.symbolType;
		decls.push(u.stmt.kind == NodeKind.ExportDecl
			? createNodeAt(NodeKind.ExportDecl, { exportedDecl: v }, loc)
			: v);
	}
	return decls;
}

function replaceStmt(program: Node, stmt: Node, by: Node[]): void {
	const pd = program.data as ProgramData;
	const at = pd.programStmts.indexOf(stmt);
	if (at < 0) throw new Error("internal: a module declaration left its program");
	pd.programStmts = [
		...pd.programStmts.slice(0, at),
		...by,
		...pd.programStmts.slice(at + 1),
	];
}

function assignmentPattern(pattern: Node | null): Node | null {
	if (pattern == null) return null;
	const loc = pattern.location;
	if (pattern.kind == NodeKind.Identifier) return pattern;
	if (pattern.kind == NodeKind.SpreadExpr) {
		const arg = (pattern.data as SpreadExprData).spreadArg;
		return arg.kind == NodeKind.Identifier ? pattern : null;
	}
	if (pattern.kind == NodeKind.ArrayPattern) {
		const d = pattern.data as ArrayPatternData;
		if (d.patternDefaults.some((x) => x != null)) return null;
		const elements: Node[] = [];
		for (const e of d.patternElements) {
			const target = assignmentPattern(e);
			if (target == null) return null;
			elements.push(target!);
		}
		const literal = createNodeAt(NodeKind.ArrayLiteral, { elements }, loc);
		literal.nodeType = pattern.nodeType;
		return literal;
	}
	if (pattern.kind != NodeKind.ObjectPattern) return null;
	const d = pattern.data as ObjectPatternData;
	if (d.hasRestProp) return null;
	const properties: Node[] = [];
	const keys: string[] = [];
	const keyLocations: SourceLocation[] = [];
	for (const p of d.patternProps) {
		const prop = p.data as ObjectPatternPropData;
		const target = prop.propDefault == null ? assignmentPattern(prop.propAlias) : null;
		if (target == null) return null;
		properties.push(target!);
		keys.push(prop.propKey);
		keyLocations.push(p.location);
	}
	const literal = createNodeAt(NodeKind.ObjectLiteral, { properties, keys, keyLocations }, loc);
	literal.nodeType = pattern.nodeType;
	return literal;
}

export function movesToWasm(u: InitUnit): boolean {
	if (u.shape != InitShape.Destructuring) return true;
	return assignmentPattern((u.decl.data as DestructuringDeclData).destrPattern) != null;
}

function takeInitializer(program: Node, u: InitUnit): Node {
	const loc = u.decl.location;
	if (u.shape == InitShape.StaticField) {
		const owner = u.owner!;
		const name = (owner.data as ClassDeclData).className;
		return staticFieldAssignment(owner, name, u.decl);
	}
	if (u.shape == InitShape.Destructuring) {
		const d = u.decl.data as DestructuringDeclData;
		const assign = makeAssign(assignmentPattern(d.destrPattern)!, d.destrInit, loc);
		replaceStmt(program, u.stmt, bareDecls(u, DeclKind.Let, []));
		return makeExprStmt(assign, loc);
	}
	const d = u.decl.data as VariableDeclData;
	const target = makeIdentResolved(u.syms[0], loc);
	const assign = makeAssign(target, d.initializer, loc);
	d.initializer = null as unknown as Node;
	return makeExprStmt(assign, loc);
}

export function applyInitThunks(
	program: Node,
	modulePath: string,
	lines: ThunkLine[],
): Result<Symbol[], string> {
	const units = initUnits(program, modulePath);
	const planned = new HashSet<int32>();
	for (const line of lines) {
		if (line.modulePath != modulePath) continue;
		const made = thunkOfLine(units, line);
		if (!made.ok) return Result.err(made.error);
		const thunk = exportedFunctionNamed(program, made.value.name);
		if (thunk == null) {
			return Result.err(`internal: the wasm half has no thunk '${made.value.name}' in '${modulePath}'`);
		}
		const body = (thunk!.data as FunctionDeclData).fnBody.data as BlockStmtData;
		const run = takeInitializer(program, made.value.unit);
		body.statements = [run, ...body.statements];
		planned.add(line.ordinal);
	}
	const dropped: Symbol[] = [];
	for (const u of units) {
		if (planned.has(u.ordinal) || !unitRunsCode(u)) continue;
		match (u.shape) {
			InitShape.Variable => {
				(u.decl.data as VariableDeclData).initializer = null as unknown as Node;
			},
			InitShape.StaticField => {
				(u.decl.data as PropertyDeclData).propInitializer = null as unknown as Node;
			},
			InitShape.Destructuring => replaceStmt(program, u.stmt, bareDecls(u, DeclKind.Let, [])),
		}
		for (const s of u.syms) dropped.push(s);
	}
	return Result.ok(dropped);
}

export function callInitThunks(
	program: Node,
	thunks: InitThunk[],
	call: (site: Node, name: string) => void,
): void {
	for (const t of thunks) {
		const u = t.unit;
		if (u.shape != InitShape.Destructuring) {
			call(initializerOf(u)!, t.name);
			continue;
		}
		const loc = u.decl.location;
		const run = makeIdentResolved(u.syms[0], loc);
		run.nodeType = null as unknown as Type;
		call(run, t.name);
		const inits: (Node | null)[] = [];
		for (let at = 0; at < u.syms.length; at += 1) {
			if (!t.getters.includes(at)) {
				inits.push(null);
				continue;
			}
			const read = makeIdentResolved(u.syms[at], loc);
			call(read, getterName(u, at as int32));
			inits.push(read);
		}
		const by = [makeExprStmt(run, loc), ...bareDecls(u, DeclKind.Let, inits)];
		replaceStmt(program, u.stmt, by);
	}
}

import { parseInput } from "../../transform/testUtil";
import { checkProgram } from "../../checker/checkPass";

function checked(lines: string[]): Node {
	const parsed = parseInput(lines.join("\n"));
	if (!parsed.ok) throw new Error(parsed.error);
	checkProgram(parsed.value);
	return parsed.value;
}

function wasmRoots(program: Node): Node[] {
	const roots: Node[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOf(stmt);
		const sym = decl.resolvedSym;
		if (decl.kind == NodeKind.FunctionDecl && sym != null && hasFlag(sym!, SymbolFlag.Wasm)) {
			roots.push(decl);
		}
	}
	return roots;
}

test "an initializer that calls, constructs or reads state runs code" {
	const program = checked([
		"function one(): int32 { return 1; }",
		"enum Color { Red, Blue }",
		"const a: int32 = 1;",
		"const b: int32 = one();",
		"const c: int32 = a + 1;",
		"const d: int32[] = [1, 2];",
		"const e = (): int32 => a;",
		"const f: Color = Color.Blue;",
	]);
	const runs = initUnits(program, "m.ms").map((u) => unitRunsCode(u));
	assert runs.join(",") == "false,true,true,false,false,false";
}

test "both builds number variables, static fields and destructurings alike" {
	const program = checked([
		"function pair(): int32[] { return [1, 2]; }",
		"let x: int32 = 1;",
		"class Cfg {",
		"\tstatic scale: int32 = 3;",
		"\tsize: int32 = 4;",
		"}",
		"const [lo, hi] = pair();",
	]);
	const units = initUnits(program, "m.ms");
	const targets = units.map((u) => targetsOf(u).join("+")).join(",");
	assert targets == "x,Cfg.scale,lo+hi", targets;
	assert units.map((u) => u.ordinal).join(",") == "0,1,2";
}

test "an initializer moves to wasm when wasm reads it, and returns when JS reads it too" {
	const program = checked([
		"function bump(v: int32): int32 { return v + 1; }",
		"const seen: int32 = bump(1);",
		"const shared: int32 = bump(2);",
		"const jsOnly: int32 = bump(3);",
		"const literal: int32 = 4;",
		"export function show(): int32 { return shared + jsOnly + literal; }",
		"@wasm",
		"export function calc(): int32 { return seen + shared + literal; }",
	]);
	const thunks = planInitThunks([program], ["m.ms"], wasmRoots(program));
	const planned = thunks.map((t) => `${targetsOf(t.unit)[0]}:${t.returns}`);
	assert planned.join(",") == "seen:false,shared:true";
}

test "wasm reaches what a moved initializer calls and reads" {
	const program = checked([
		"function bump(v: int32): int32 { return v + 1; }",
		"const base: int32 = bump(1);",
		"function scaled(): int32 { return base * 2; }",
		"const k: int32 = scaled();",
		"@wasm",
		"export function calc(): int32 { return k; }",
	]);
	const thunks = planInitThunks([program], ["m.ms"], wasmRoots(program));
	assert thunks.map((t) => targetsOf(t.unit)[0]).join(",") == "base,k";
}

test "a plan line survives the trip to the wasm half" {
	const line: ThunkLine = {
		modulePath: "/p/m.ms",
		ordinal: 3,
		targets: ["lo", "hi"],
		returns: false,
		getters: [1],
	};
	const decoded = decodeThunks(encodeThunks([line]));
	assert decoded.ok;
	assert encodeThunks(decoded.value) == encodeThunks([line]);
	assert !decodeThunks("/p/m.ms\tx\tlo\t0\t\n").ok;
	assert thunkSource(line).includes("export function msbInit3(): void {}");
	assert thunkSource(line).includes("export function msbInit3_1() {\n\treturn hi;\n}");
}

test "the wasm half runs a planned initializer in its thunk and drops the rest" {
	const program = checked([
		"function bump(v: int32): int32 { return v + 1; }",
		"const seen: int32 = bump(1);",
		"const jsOnly: int32 = bump(3);",
		"const literal: int32 = 4;",
		"@wasm",
		"export function msbInit0(): void {}",
	]);
	const line: ThunkLine = {
		modulePath: "m.ms",
		ordinal: 0,
		targets: ["seen"],
		returns: false,
		getters: [],
	};
	const dropped = applyInitThunks(program, "m.ms", [line]);
	assert dropped.ok;
	assert dropped.value.map((s) => s.name).join(",") == "jsOnly";
	const units = initUnits(program, "m.ms");
	assert units.map((u) => targetsOf(u)[0]).join(",") == "literal";
	const thunk = exportedFunctionNamed(program, "msbInit0")!;
	const body = (thunk.data as FunctionDeclData).fnBody.data as BlockStmtData;
	assert body.statements.length == 1;
	assert body.statements[0].kind == NodeKind.ExprStmt;
}
