import { Node, NodeKind, Symbol, SymbolState, Type, ProgramData, ExportDeclData, ClassDeclData, ActorDeclData, MethodDeclData, PropertyDeclData, ExternDeclData } from "../../ast/node";
import { declOfStatement, getDeclName, classMemberDecl } from "../../checker/collectPass";
import { ScopeKind, SymbolTable, SymbolFlag, lookupLocal, openScope, symbolKey } from "../../checker/symbol";
import { CheckerContext, createContext } from "../../checker/context";
import { collectTopLevel } from "../../checker/collectPass";
import { resetResizeSummaries } from "../../checker/varPartitions";
import { parseSource } from "../../parser/statements/validation";

class Declared {
	key: Node;
	probe: Node;
	probeInner: Node;
	name: string;
	group: string;
}

export class AdoptedPair {
	sym: Symbol;
	owner: Symbol | null;
	name: string;
	before: string;
}

export class Adoption {
	decls: HashMap<Node, Symbol> = new HashMap<Node, Symbol>();
	pairs: AdoptedPair[] = [];
	visited: HashSet<Node> = new HashSet<Node>();
	old: OldSide = new OldSide();
	index: HashMap<string, Declared> = new HashMap<string, Declared>();
	seen: HashMap<string, int32> = new HashMap<string, int32>();
	summariesDropped: boolean = false;
}

function memberKey(owner: Symbol | null, name: string, sym: Symbol): string {
	return owner == null ? symbolKey(sym) : `${symbolKey(owner)}.${name}`;
}

function groupOf(decl: Node): string {
	if (decl.kind != NodeKind.ExternDecl) return `${decl.kind as int32}`;
	return `${decl.kind as int32}.${(decl.data as ExternDeclData).externKind as int32}`;
}

function topDecls(program: Node): Declared[] {
	const out: Declared[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = declOfStatement(stmt);
		const name = getDeclName(decl);
		if (name == "") continue;
		out.push({ key: decl, probe: decl, probeInner: decl, name: name, group: groupOf(decl) });
	}
	return out;
}

function memberDecls(body: Node[]): Declared[] {
	const out: Declared[] = [];
	for (const raw of body) {
		const inner = classMemberDecl(raw);
		if (inner.kind == NodeKind.MethodDecl) {
			out.push({ key: raw, probe: raw, probeInner: inner, name: (inner.data as MethodDeclData).methodName, group: "method" });
		} else if (inner.kind == NodeKind.PropertyDecl && (inner.data as PropertyDeclData).propIsStatic) {
			out.push({ key: inner, probe: inner, probeInner: inner, name: (inner.data as PropertyDeclData).propName, group: "static" });
		}
	}
	return out;
}

function classBodyOf(decl: Node): Node[] | null {
	if (decl.kind == NodeKind.ClassDecl) return (decl.data as ClassDeclData).classBody;
	if (decl.kind == NodeKind.ActorDecl) return (decl.data as ActorDeclData).actorBody;
	return null;
}

function indexByOrdinal(decls: Declared[]): HashMap<string, Declared> {
	const index = new HashMap<string, Declared>();
	const seen = new HashMap<string, int32>();
	for (const d of decls) {
		index.set(ordinalKey(d, seen), d);
	}
	return index;
}

function ordinalKey(d: Declared, seen: HashMap<string, int32>): string {
	const slot = `${d.group}\t${d.name}`;
	const ordinal = seen.get(slot) ?? 0;
	seen.set(slot, ordinal + 1);
	return `${slot}\t${ordinal}`;
}

class OldSide {
	byDecl: HashMap<Node, Symbol> = new HashMap<Node, Symbol>();
	modulePath: string = "";
}

function oldSymbol(old: OldSide, d: Declared): Symbol | null {
	const sym = d.probe.resolvedSym ?? d.probeInner.resolvedSym ?? old.byDecl.get(d.probe);
	if (sym == null || sym.modulePath != old.modulePath) return null;
	return sym;
}

function pair(out: Adoption, was: Declared, now: Declared, owner: Symbol | null): Symbol | null {
	const sym = oldSymbol(out.old, was);
	if (sym == null) return null;
	out.decls.set(now.key, sym);
	out.pairs.push({ sym: sym, owner: owner, name: now.name, before: memberKey(owner, now.name, sym) });
	return sym;
}

function pairMembers(out: Adoption, was: Declared[], now: Declared[], owner: Symbol): void {
	const index = indexByOrdinal(was);
	const seen = new HashMap<string, int32>();
	for (const n of now) {
		const w = index.get(ordinalKey(n, seen));
		if (w != null) pair(out, w, n, owner);
	}
}

// The old program's declarations, indexed by kind of declaration, name and ordinal among
// same-named declarations in statement order, the order disamb is minted in.
export function adoptDecls(oldProgram: Node, oldSymbols: Symbol[], modulePath: string): Adoption {
	const out = new Adoption();
	out.old.modulePath = modulePath;
	for (const sym of oldSymbols) {
		if (sym.declNode != null) out.old.byDecl.set(sym.declNode, sym);
		for (const o of sym.overloads) {
			if (o.declNode != null) out.old.byDecl.set(o.declNode, o);
		}
	}
	out.index = indexByOrdinal(topDecls(oldProgram));
	return out;
}

// Called for each statement just before it is collected, so a statement a module pass
// rewrote or a macro or decorator generated pairs by the same key as a written one.
// A declaration with no counterpart, or of another kind, gets a new Symbol.
export function adoptStmt(out: Adoption, stmt: Node): void {
	const decl = declOfStatement(stmt);
	const name = getDeclName(decl);
	if (name == "" || out.visited.has(decl)) return;
	out.visited.add(decl);
	const now: Declared = { key: decl, probe: decl, probeInner: decl, name: name, group: groupOf(decl) };
	const was = out.index.get(ordinalKey(now, out.seen));
	if (was == null) return;
	const sym = pair(out, was, now, null);
	if (sym != null && !out.summariesDropped) {
		out.summariesDropped = true;
		resetResizeSummaries();
	}
	const wasBody = classBodyOf(was.key);
	const nowBody = classBodyOf(decl);
	if (sym == null || wasBody == null || nowBody == null) return;
	pairMembers(out, memberDecls(wasBody), memberDecls(nowBody), sym);
}

export function moduleSymbols(table: SymbolTable, modulePath: string): Symbol[] {
	const out: Symbol[] = [];
	for (const scope of table.allScopes) {
		if (scope.scopeKind != ScopeKind.Module) continue;
		for (const sym of scope.symbols.values()) {
			if (sym.modulePath == modulePath) out.push(sym);
		}
	}
	return out;
}

export function verifyAdoption(adoption: Adoption): void {
	for (const p of adoption.pairs) {
		const now = memberKey(p.owner, p.name, p.sym);
		if (now != p.before) throw new Error(`internal: adoption: '${p.before}' was adopted by a declaration that is now '${now}'`);
	}
}

const testPath = "/adopt/m.ms";

class Collected {
	ctx: CheckerContext;
	program: Node;
	adoption: Adoption | null;
}

function collectText(text: string, previous: Collected | null): Collected {
	const parsed = parseSource(text);
	if (!parsed.ok) throw new Error(`test source does not parse: ${text}`);
	const ctx = createContext();
	ctx.modulePath = testPath;
	openScope(ctx.table, ScopeKind.Module);
	let adoption: Adoption | null = null;
	if (previous != null) {
		const taken = adoptDecls(previous.program, moduleSymbols(previous.ctx.table, testPath), testPath);
		adoption = taken;
		ctx.adoptedDecls = taken.decls;
		ctx.adoptStmt = (stmt: Node): void => adoptStmt(taken, stmt);
	}
	collectTopLevel(ctx, parsed.value);
	if (adoption != null) verifyAdoption(adoption);
	return { ctx: ctx, program: parsed.value, adoption: adoption };
}

function symbolOf(c: Collected, name: string): Symbol {
	const sym = lookupLocal(c.ctx.table, name);
	if (sym == null) throw new Error(`no symbol ${name}`);
	return sym;
}

function methodSymbol(c: Collected, owner: string, name: string): Symbol {
	for (const stmt of (c.program.data as ProgramData).programStmts) {
		const decl = declOfStatement(stmt);
		const body = classBodyOf(decl);
		if (body == null || getDeclName(decl) != owner) continue;
		for (const d of memberDecls(body)) {
			if (d.group == "method" && d.name == name && d.probe.resolvedSym != null) return d.probe.resolvedSym;
		}
	}
	throw new Error(`no method ${name}`);
}

const exportedOne = "export function one(): int32 { return 1; }";

test "a declaration inserted above keeps every other declaration's Symbol and takes the new position" {
	const first = collectText(exportedOne + "\nfunction helper(): int32 { return 2; }", null);
	const one = symbolOf(first, "one");
	const helper = symbolOf(first, "helper");
	assert one.location.line == 1;
	const second = collectText("export const fresh: int32 = 9;\n\n" + exportedOne + "\nfunction helper(): int32 { return 2; }", first);
	assert symbolOf(second, "one") == one;
	assert symbolOf(second, "helper") == helper;
	assert one.location.line == 3;
	assert one.declNode == ((second.program.data as ProgramData).programStmts[1].data as ExportDeclData).exportedDecl;
	assert symbolOf(second, "fresh") != one;
	const third = collectText("export class Fresh {}\n" + exportedOne, second);
	assert symbolOf(third, "one") == one;
	assert one.location.line == 2;
}

test "an overload added below pairs the first with the first, and one removed above pairs by position" {
	const single = "export function f(x: int32): int32 { return x; }";
	const double = single + "\nexport function f(x: string): string { return x; }";
	const first = collectText(single, null);
	const f = symbolOf(first, "f");
	const second = collectText(double, first);
	assert symbolOf(second, "f") == f;
	assert f.disamb == 0;
	assert f.overloads.length == 1;
	const added = f.overloads[0];
	assert added.disamb == 1;
	const third = collectText(double, second);
	assert symbolOf(third, "f") == f;
	assert f.overloads[0] == added;
	const fourth = collectText(single, third);
	assert symbolOf(fourth, "f") == f;
	assert f.overloads.length == 0;
	assert f.disamb == 0;
}

test "a class member pairs by owner and name, a static member too, wherever it sits" {
	const body = "export class C { static s: int32 = 1; m(): int32 { return 1; } n(): int32 { return 2; } }";
	const moved = "export class C { k(): int32 { return 0; } n(): int32 { return 2; } static s: int32 = 1; m(): int32 { return 1; } }";
	const first = collectText(body, null);
	const c = symbolOf(first, "C");
	const s = c.staticFields[0];
	const m = methodSymbol(first, "C", "m");
	const second = collectText(moved, first);
	assert symbolOf(second, "C") == c;
	assert c.staticFields.length == 1 && c.staticFields[0] == s;
	assert methodSymbol(second, "C", "m") == m;
	assert m.declNode.location.line == 1;
	assert methodSymbol(second, "C", "k") != m;
	const other = collectText("export class D { m(): int32 { return 1; } }\n" + body, second);
	assert symbolOf(other, "C") == c;
	assert methodSymbol(other, "C", "m") == m;
}

test "a kind change is not paired, and a Symbol forced onto another kind refuses loudly" {
	const first = collectText(exportedOne, null);
	const one = symbolOf(first, "one");
	const classed = parseSource("export class one {}");
	assert classed.ok;
	const adoption = adoptDecls(first.program, moduleSymbols(first.ctx.table, testPath), testPath);
	adoptStmt(adoption, (classed.value.data as ProgramData).programStmts[0]);
	assert adoption.decls.size == 0;
	const ctx = createContext();
	ctx.modulePath = testPath;
	openScope(ctx.table, ScopeKind.Module);
	const decl = declOfStatement((classed.value.data as ProgramData).programStmts[0]);
	ctx.adoptedDecls.set(decl, one);
	let message = "";
	try {
		collectTopLevel(ctx, classed.value);
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.startsWith("internal: adoption:");
}

test "an adopted Symbol is reinitialised from its new declaration" {
	const first = collectText("export function g(x: int32): int32 { return x; }\nexport class K { m(): int32 { return 1; } }", null);
	const g = symbolOf(first, "g");
	g.mutatedParams = 5;
	g.nativeName = "stale";
	g.symFlags = g.symFlags.incl(SymbolFlag.Used);
	const k = symbolOf(first, "K");
	k.ctorRoutine = g;
	const kType = k.symbolType;
	const second = collectText("\n\n\nexport function g(x: int32): int32 { return x; }\nexport class K { m(): int32 { return 1; } }", first);
	assert symbolOf(second, "g") == g;
	assert g.mutatedParams == 0 && g.nativeName == "" && !g.symFlags.has(SymbolFlag.Used);
	assert g.location.line == 4 && g.state == SymbolState.Hollow;
	assert symbolOf(second, "K") == k && k.symbolType == kType && k.ctorRoutine == null;
}

test "an adoption whose key moved fails loud after the check" {
	const first = collectText(exportedOne, null);
	const second = collectText("\n" + exportedOne, first);
	assert second.adoption != null;
	symbolOf(second, "one").disamb = 4;
	let message = "";
	try {
		verifyAdoption(second.adoption!);
	} catch (e) {
		message = (e as Error).message;
	}
	assert message == "internal: adoption: 'one.0./adopt/m.ms' was adopted by a declaration that is now 'one.4./adopt/m.ms'";
}

test "every kind of top-level declaration keeps its Symbol and its Type object across a shift" {
	const src = "export interface I { a: int32 }\nexport type A = int32;\nexport enum E { X, Y }\nexport const v: int32 = 1;\nextern function ext(): void;\nexport class K { a: int32 }";
	const first = collectText(src, null);
	const names = ["I", "A", "E", "v", "ext", "K"];
	const syms: Symbol[] = [];
	const types: Type[] = [];
	for (const name of names) {
		syms.push(symbolOf(first, name));
		types.push(symbolOf(first, name).symbolType);
	}
	const second = collectText("\n\n" + src, first);
	for (let i = 0; i < names.length; i++) {
		assert symbolOf(second, names[i]) == syms[i];
		assert syms[i].symbolType == types[i] || names[i] == "v" || names[i] == "ext";
		assert syms[i].location.line == i + 3;
	}
}

test "a top-level name equal to a method's mangled name keeps both keys apart across a shift" {
	const src = "export class C { m(): int32 { return 1; } }\nexport function C_m(): int32 { return 2; }";
	const first = collectText(src, null);
	const c = symbolOf(first, "C");
	const cm = symbolOf(first, "C_m");
	const m = methodSymbol(first, "C", "m");
	const second = collectText("\n" + src, first);
	assert symbolOf(second, "C") == c;
	assert symbolOf(second, "C_m") == cm;
	assert methodSymbol(second, "C", "m") == m;
}
