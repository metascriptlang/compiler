import { AttachedOp, Node, NodeKind, ProgramData, Symbol, TypeKind, SymbolKind, Type } from "../../ast/node";
import { TransformContext, createTransformContextWithChecker, reportTransformError } from "../context";
import { forEachChild } from "../../ast/visitor";
import { findSharedBooleanDiscriminant, findSharedStringDiscriminant } from "../../checker/types";
import { checkProgram } from "../../checker/checkPass";
import { getDeclName } from "../../checker/collectPass";
import { getOpByKey } from "../../codegen/c/types";
import { lowerBuiltins } from "../native/builtinLower";
import { parseInput, getStmts } from "../testUtil";

// Every symbol a subtree references. An enum member use references its enum,
// and so does a type that names it: a generic instance bound to the enum
// may call its toString from another module.
function collectRefs(node: Node, refs: HashSet<Symbol>, seen: HashSet<Type>): void {
	if (node == null) return;
	collectEnumsOfType(node.nodeType, refs, seen);
	const sym = node.resolvedSym;
	if (sym != null) {
		refs.add(sym);
		const owner = enumOwnerOf(sym);
		if (owner != null) refs.add(owner);
	}
	if (node.kind == NodeKind.Identifier) return;
	forEachChild(node, (child: Node): void => {
		collectRefs(child, refs, seen);
	});
}

function collectEnumsOfType(t: Type | null, refs: HashSet<Symbol>, seen: HashSet<Type>): void {
	if (t == null || seen.has(t)) return;
	seen.add(t);
	if (t.kind == TypeKind.Enum) {
		if (t.sym != null) refs.add(t.sym);
		return;
	}
	collectEnumsOfType(t.typeReturn, refs, seen);
	collectEnumsOfType(t.typeExtra, refs, seen);
	if (t.typeChildren != null) {
		for (const c of t.typeChildren) collectEnumsOfType(c, refs, seen);
	}
}

function enumOwnerOf(sym: Symbol): Symbol | null {
	if (sym.symbolKind == SymbolKind.Function) return enumOfToStringOp(sym);
	if (sym.symbolKind != SymbolKind.EnumMember) return null;
	let t: Type | null = sym.symbolType;
	if (t != null && t.kind == TypeKind.EnumLiteral) t = t.typeReturn;
	return t != null && t.kind == TypeKind.Enum ? t.sym : null;
}

function enumOfToStringOp(sym: Symbol): Symbol | null {
	const ft = sym.symbolType;
	if (ft == null || ft.kind != TypeKind.Function || ft.typeChildren == null || ft.typeChildren.length != 1) return null;
	const t = ft.typeChildren[0];
	if (t.kind != TypeKind.Enum || t.sym == null) return null;
	return getOpByKey(t, AttachedOp.AttachedToString) == sym ? t.sym : null;
}

// Returns true for declarations that can be eliminated if unreferenced.
// Reference parity: function-level DCE is handled by codegen (functionDeclIsAlive with
// cross-module visibility), NOT by transform-level DCE (per-module, no cross-module refs).
// Only type aliases and enums are safe to eliminate at transform level.
//
// Exception: TypeAliasDecls that resolve to discriminated unions (match-type or
// TS-style with shared literal discriminator) need destructor lifting to emit
// per-variant hooks. DCE's identifier walker doesn't track type-level references
// (annotation strings, not Identifier nodes), so any DU alias would be eliminated
// before destructorLifting can emit `<Name>Destroy`. Keep them alive.
function isEliminable(node: Node): boolean {
	if (node.kind == NodeKind.EnumDecl) return true;
	if (node.kind == NodeKind.TypeAliasDecl) {
		// Discriminated-union aliases need destructor lifting to emit per-variant
		// hooks. DCE's identifier walker can't track type-level references
		// (annotation strings, not Identifier nodes), so any DU alias would be
		// eliminated before destructorLifting saw it, leaving `<Name>Destroy`
		// undefined at link time. Detect three DU shapes:
		//  - Stamped (typeNames[0] + typeExtra): match-type or boolean DU.
		//  - Boolean-discriminator union: detected via findSharedBooleanDiscriminant.
		//  - String-discriminator union: detected via findSharedStringDiscriminant.
		// Other aliases stay eliminable (transparent to the C emitter).
		const sym = node.resolvedSym;
		if (sym != null && sym.symbolType != null) {
			const t = sym.symbolType;
			if (t.kind == TypeKind.Union) {
				if (t.typeNames != null && t.typeNames.length > 0 && t.typeExtra != null) return false;
				if (findSharedBooleanDiscriminant(t) != "") return false;
				if (findSharedStringDiscriminant(t) != "") return false;
			}
		}
		return true;
	}
	return false;
}

// Mark-sweep reachability on top-level declarations: seed from the declarations that stay, close over what they reference, drop the rest.
export function sweepDeadDecls(program: Node, ctx: TransformContext): void {
	if (program.kind != NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const stmts = pd.programStmts;
	if (stmts.length == 0) return;

	const declSyms: (Symbol | null)[] = [];
	let anyEliminable = false;
	for (const stmt of stmts) {
		if (!isEliminable(stmt)) {
			declSyms.push(null);
			continue;
		}
		if (stmt.resolvedSym == null) {
			reportTransformError(ctx, `internal: dead-declaration sweep met '${getDeclName(stmt)}' without a symbol`, stmt.location);
			return;
		}
		declSyms.push(stmt.resolvedSym);
		anyEliminable = true;
	}
	if (!anyEliminable) return;

	const refs = new HashSet<Symbol>();
	const seen = new HashSet<Type>();
	for (let si = 0; si < stmts.length; si += 1) {
		if (declSyms[si] == null) collectRefs(stmts[si], refs, seen);
	}

	const alive = new HashSet<Symbol>();
	let changed = true;
	while (changed) {
		changed = false;
		for (let di = 0; di < stmts.length; di += 1) {
			const sym = declSyms[di];
			if (sym != null && refs.has(sym) && !alive.has(sym)) {
				alive.add(sym);
				collectRefs(stmts[di], refs, seen);
				changed = true;
			}
		}
	}

	const result: Node[] = [];
	for (let fi = 0; fi < stmts.length; fi += 1) {
		const sym = declSyms[fi];
		if (sym == null || alive.has(sym)) result.push(stmts[fi]);
	}
	pd.programStmts = result;
}

function sweptStmtCount(input: string): int32 {
	const pr = parseInput(input);
	if (!pr.ok) return -1;
	sweepDeadDecls(pr.value, createTransformContextWithChecker(checkProgram(pr.value)));
	return getStmts(pr.value).length;
}

test "unused enum removed" { assert sweptStmtCount("enum Color { Red, Green } const x = 1;") == 1; }

test "an enum used only through a member stays" { assert sweptStmtCount("enum Color { Red, Green } const x = Color.Green;") == 2; }

test "an enum reached only through its toString op stays" {
	const pr = parseInput("enum Shade { Lo, Hi } const a: int32 = 1; const s: string = Shade[a];");
	assert pr.ok;
	const ctx = createTransformContextWithChecker(checkProgram(pr.value));
	const lowered = lowerBuiltins(pr.value, ctx);
	sweepDeadDecls(lowered, ctx);
	assert getStmts(lowered).length == 3;
}

test "an enum named only by a type stays" {
	assert sweptStmtCount("enum Shade { Lo, Hi } const n: int32 = 1; const s = n as Shade;") == 3;
	assert sweptStmtCount("enum Shade { Lo, Hi } struct Lamp { shade: BitSet<Shade>; } const n: int32 = 1;") == 3;
	assert sweptStmtCount("enum Shade { Lo, Hi } function lit(s: Shade): int32 { return s as int32; } const n: int32 = 1;") == 3;
}

test "a local that shares an enum's name does not keep the enum" {
	assert sweptStmtCount("enum Color { Red } function f(): number { const Color = 1; return Color; } f();") == 2;
}
