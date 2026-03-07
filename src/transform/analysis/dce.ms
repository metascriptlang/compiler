// Dead Code Elimination — Nim-aligned two-tier design
//
// Level 1 (this file): Statement-level AST transform
//   - endsInNoReturn: recursive path analysis (Nim's semstmts.nim pattern)
//   - Never-returning call detection (Nim's sfNoReturn / TypeScript's `: never`)
//   - Strips unreachable statements after terminators AND compound no-return nodes
//   - Eliminates dead branches: if(true) → consequent, if(false) → alternate
//   - Eliminates dead while: while(false) → empty block
//   - Preserves hoisted declarations (function, class, enum, interface, etc.)
//
// Level 2 (this file): Symbol-level dead declaration elimination
//   Mark-sweep reachability: seed entry points → transitive closure → sweep dead decls
//   AliveSyms API for Phase 5 codegen: isAlive(syms, name) → boolean
//
// Pipeline position: step 19 of 20 (after constantFolding, matchLower, lambdaLifting;
// before destructorLifting). By this point if(true)/if(false) conditions are already
// BooleanLiteral nodes from constant folding at step 2.

import {
	Node, NodeKind,
	ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData,
	FunctionExprData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
	IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	DoWhileStmtData, SwitchStmtData, SwitchCaseData, TryCatchStmtData,
	BooleanLiteralData, ExprStmtData, CallExprData, IdentifierData,
} from "../../ast/node";
import { TransformContext, createTransformContextWithChecker, NameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren } from "../walker";
import { TypeKind, createFunction, neverType, voidType } from "../../checker/types";
import { lookupSymbol, makeSymbol, SymbolKind, defineSymbol } from "../../checker/symbol";
import { CheckerContext, createContext } from "../../checker/context";
import { getDeclName } from "../../checker/collectPass";
import { makeBlock } from "../util";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts } from "../testUtil";

// ===== AliveSyms (Level 2 — public API for Phase 5 codegen) =====

export function createAliveSyms(): NameSet {
	const syms: NameSet = [];
	return syms;
}

export function markAlive(syms: NameSet, name: string): void {
	nameSetAdd(syms, name);
}

export function isAlive(syms: NameSet, name: string): boolean {
	return nameSetContains(syms, name);
}

// ===== Helpers =====

function isHoistedDecl(node: Node): boolean {
	return match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ClassDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.TypeAliasDecl
			| NodeKind.ImportDecl | NodeKind.ExportDecl | NodeKind.ExternDecl => true,
		_ => false,
	};
}

function isTrueLiteral(node: Node): boolean {
	if (node.kind !== NodeKind.BooleanLiteral) return false;
	const d = node.data as BooleanLiteralData;
	return d.boolValue === true;
}

function isFalseLiteral(node: Node): boolean {
	if (node.kind !== NodeKind.BooleanLiteral) return false;
	const d = node.data as BooleanLiteralData;
	return d.boolValue === false;
}

// ===== Never-Returning Call Detection (Nim's sfNoReturn) =====

function isNeverCall(node: Node, ctx: TransformContext): boolean {
	if (ctx.checkerCtx === null) return false;
	const d = node.data as CallExprData;
	if (d.callee.kind !== NodeKind.Identifier) return false;
	const name = (d.callee.data as IdentifierData).name;
	const sym = lookupSymbol(ctx.checkerCtx.table, name);
	if (sym === null) return false;
	if (sym.symbolType.kind !== TypeKind.Function) return false;
	return sym.symbolType.typeReturn.kind === TypeKind.Never;
}

// ===== Level 2: Symbol-level Dead Declaration Elimination =====
// Mark-sweep reachability on top-level declarations.
// Nim equivalent: ic/dce.nim (AliveSyms mark-sweep worklist)
// Reference equivalent: transform/dce.zig (computeAliveSymsMultiModule)

// Collect all Identifier names referenced in a subtree.
// Uses mapChildren from walker.ms for exhaustive 40+ node kind coverage.
function collectIdentifiers(node: Node, refs: NameSet): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		nameSetAdd(refs, d.name);
		return;
	}
	mapChildren(node, (child: Node): Node => {
		collectIdentifiers(child, refs);
		return child;
	});
}

// Returns true for declarations that can be eliminated if unreferenced.
// Everything else (statements, imports, exports, variables) has side effects.
function isEliminable(node: Node): boolean {
	return match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ClassDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.TypeAliasDecl => true,
		_ => false,
	};
}

// Compiler-generated names are always alive (produced by transforms).
function isCompilerGenerated(name: string): boolean {
	if (name.length === 0) return false;
	const first = name.slice(0, 1);
	if (first === "$") return true;
	if (name.length >= 8) {
		const prefix = name.slice(0, 8);
		if (prefix === "__lifted") return true;
	}
	return false;
}

// Pre-computed per-stmt name list (avoids repeated getDeclName calls — DRC string return bug)
type StmtNames = string[];

// Main Level 2 algorithm: mark-sweep reachability on top-level declarations.
function sweepDeadDecls(program: Node, ctx: TransformContext): void {
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const stmts = pd.programStmts;
	if (stmts.length === 0) return;

	// Phase 1: Pre-compute names for ALL stmts (one getDeclName call per stmt, stored safely)
	const names: StmtNames = [];
	const declNames: NameSet = [];
	for (let idx = 0; idx < stmts.length; idx += 1) {
		const n = getDeclName(stmts[idx]);
		names.push(n);
		if (n.length > 0 && isEliminable(stmts[idx])) {
			nameSetAdd(declNames, n);
		}
	}
	if (declNames.length === 0) return;

	// Phase 2: Seed — collect identifier refs from all non-eliminable stmts (entry points)
	const refs: NameSet = [];
	for (let si = 0; si < stmts.length; si += 1) {
		if (!isEliminable(stmts[si])) {
			collectIdentifiers(stmts[si], refs);
		}
	}

	// Phase 3: Transitive closure — fixpoint iteration using pre-computed names
	const alive: NameSet = [];
	// User-defined main() is always alive (called by dispatcher, not user code)
	if (nameSetContains(declNames, "main")) {
		nameSetAdd(alive, "main");
		// Also seed refs from main's body
		for (let mi = 0; mi < stmts.length; mi += 1) {
			const mn = names[mi];
			if (mn === "main") {
				collectIdentifiers(stmts[mi], refs);
			}
		}
	}
	let changed = true;
	while (changed) {
		changed = false;
		for (let di = 0; di < stmts.length; di += 1) {
			if (isEliminable(stmts[di])) {
				const n = names[di];
				if (n.length > 0 && nameSetContains(refs, n) && !nameSetContains(alive, n)) {
					nameSetAdd(alive, n);
					collectIdentifiers(stmts[di], refs);
					changed = true;
				}
			}
		}
	}

	// Phase 4: Sweep — filter using pre-computed names (no getDeclName calls)
	const result: Node[] = [];
	for (let fi = 0; fi < stmts.length; fi += 1) {
		if (!isEliminable(stmts[fi])) {
			result.push(stmts[fi]);
		} else {
			const n = names[fi];
			if (nameSetContains(alive, n) || isCompilerGenerated(n)) {
				result.push(stmts[fi]);
			}
		}
	}
	pd.programStmts = result;
}

// ===== endsInNoReturn — Nim's recursive path analysis =====
// Returns true if a node ALWAYS terminates control flow (never falls through).
// Nim equivalent: semstmts.nim:endsInNoReturn
//
// Direct terminators: return, throw, break, continue, unreachable
// Never-returning calls: ExprStmt wrapping CallExpr to `: never` function
// Compound terminators:
//   - BlockStmt: last statement endsInNoReturn
//   - IfStmt: ALL branches + else must endsInNoReturn
//   - SwitchStmt: ALL cases + default must endsInNoReturn
//   - TryCatchStmt: finally endsInNoReturn OR (try + all catches endsInNoReturn)

export function endsInNoReturn(node: Node, ctx: TransformContext): boolean {
	return match (node.kind) {
		// Direct terminators (Nim's nkLastBlockStmts + unreachable)
		NodeKind.ReturnStmt | NodeKind.ThrowStmt | NodeKind.BreakStmt
			| NodeKind.ContinueStmt | NodeKind.UnreachableStmt => true,

		// ExprStmt: unwrap and check inner expression (e.g. fail() call)
		NodeKind.ExprStmt => {
			const ed = node.data as ExprStmtData;
			endsInNoReturn(ed.expr, ctx)
		},

		// CallExpr: check if callee returns never (Nim's sfNoReturn)
		NodeKind.CallExpr => {
			isNeverCall(node, ctx)
		},

		// Block: check last statement
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			if (d.statements.length === 0) { false }
			else { endsInNoReturn(d.statements[d.statements.length - 1], ctx) }
		},

		// If/else: ALL branches must terminate AND must have else
		// Nim: only noReturn when hasElse && all branches noReturn
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			// Must have a non-empty alternate (else branch)
			if (d.alternate === null) { false }
			else if (d.alternate.kind === NodeKind.BlockStmt) {
				const altBlock = d.alternate.data as BlockStmtData;
				if (altBlock.statements.length === 0) { false }
				else {
					// Both branches must terminate
					endsInNoReturn(d.consequent, ctx) && endsInNoReturn(d.alternate, ctx)
				}
			}
			else {
				// alternate is another IfStmt (else-if chain)
				endsInNoReturn(d.consequent, ctx) && endsInNoReturn(d.alternate, ctx)
			}
		},

		// Switch: ALL cases must terminate AND must have default
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (d.switchCases.length === 0) { false }
			else { switchEndsInNoReturn(d.switchCases, ctx) }
		},

		// Try/catch/finally:
		// - If finally endsInNoReturn → whole thing is noReturn (Nim: special override)
		// - Otherwise: try body + ALL catch handlers must endsInNoReturn
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			// Finally override: if finally always terminates, entire try is noReturn
			if (d.finallyBody !== null && endsInNoReturn(d.finallyBody, ctx)) { true }
			else {
				// Try body must terminate
				if (!endsInNoReturn(d.tryBody, ctx)) { false }
				// Catch body must terminate (if present)
				else if (d.catchBody !== null) { endsInNoReturn(d.catchBody, ctx) }
				// No catch: try body terminates but exceptions could escape
				else { false }
			}
		},

		_ => false,
	};
}

// Helper: check if all switch cases terminate AND has default
function switchEndsInNoReturn(cases: Node[], ctx: TransformContext): boolean {
	let hasDefault = false;
	for (let i = 0; i < cases.length; i += 1) {
		const c = cases[i];
		if (c.kind === NodeKind.SwitchCase) {
			const cd = c.data as SwitchCaseData;
			if (cd.isDefault) { hasDefault = true; }
			// Check if case body terminates
			if (cd.caseStmts.length === 0) return false;
			if (!endsInNoReturn(cd.caseStmts[cd.caseStmts.length - 1], ctx)) return false;
		}
	}
	// Only noReturn when we have a default case (exhaustive)
	return hasDefault;
}

// ===== Core: Strip Unreachable Statements =====
// Uses endsInNoReturn for compound terminator detection

function stripDead(stmts: Node[], ctx: TransformContext): Node[] {
	const result: Node[] = [];
	let terminated = false;
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (terminated) {
			// After terminator: only keep hoisted declarations
			if (isHoistedDecl(stmt)) {
				result.push(stmt);
			}
		} else {
			result.push(stmt);
			if (endsInNoReturn(stmt, ctx)) {
				terminated = true;
			}
		}
	}
	return result;
}

// ===== Core: Dead Branch Elimination =====

function eliminateDeadBranch(node: Node): Node {
	if (node.kind !== NodeKind.IfStmt) return node;
	const d = node.data as IfStmtData;

	if (isTrueLiteral(d.condition)) {
		// if (true) A else B → A
		return d.consequent;
	}
	if (isFalseLiteral(d.condition)) {
		// if (false) A else B → B (parser guarantees alternate is empty BlockStmt, not null)
		return d.alternate;
	}
	return node;
}

// ===== Core: Dead While Elimination =====

function eliminateDeadWhile(node: Node): Node {
	if (node.kind !== NodeKind.WhileStmt) return node;
	const d = node.data as WhileStmtData;

	if (isFalseLiteral(d.whileCondition)) {
		return makeBlock([], node.location);
	}
	return node;
}

// ===== Statement List Walker =====
// Bottom-up: recurse into each stmt, then apply dead branch/while elimination

function walkStmtList(stmts: Node[], ctx: TransformContext): void {
	for (let i = 0; i < stmts.length; i += 1) {
		dceInNode(stmts[i], ctx);
		stmts[i] = eliminateDeadBranch(stmts[i]);
		stmts[i] = eliminateDeadWhile(stmts[i]);
	}
}

// ===== Recursive DCE Walker =====

function dceInNode(node: Node, ctx: TransformContext): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			walkStmtList(d.programStmts, ctx);
			d.programStmts = stripDead(d.programStmts, ctx);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			walkStmtList(d.statements, ctx);
			d.statements = stripDead(d.statements, ctx);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			dceInNode(d.fnBody, ctx);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			dceInNode(d.arrowBody, ctx);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			dceInNode(d.funcExprBody, ctx);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			dceInNode(d.methodBody, ctx);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			dceInNode(d.ctorBody, ctx);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			dceInNode(d.consequent, ctx);
			dceInNode(d.alternate, ctx);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			dceInNode(d.whileBody, ctx);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			dceInNode(d.forBody, ctx);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			dceInNode(d.forOfBody, ctx);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			dceInNode(d.forInBody, ctx);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			dceInNode(d.doBody, ctx);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			for (const c of d.switchCases) {
				dceInNode(c, ctx);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			walkStmtList(d.caseStmts, ctx);
			d.caseStmts = stripDead(d.caseStmts, ctx);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			dceInNode(d.tryBody, ctx);
			if (d.catchBody !== null) {
				dceInNode(d.catchBody, ctx);
			}
			if (d.finallyBody !== null) {
				dceInNode(d.finallyBody, ctx);
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			dceInNode(d.exportedDecl, ctx);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) {
				dceInNode(member, ctx);
			}
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			dceInNode(d.decoratedNode, ctx);
		},
		_ => {},
	};
}

// ===== Main Entry Point =====

export function lowerDCE(program: Node, ctx: TransformContext): Node {
	dceInNode(program, ctx);         // Level 1: statement-level DCE
	sweepDeadDecls(program, ctx);    // Level 2: symbol-level DCE
	return program;
}

// ===== Test Helper: DCE with checker context =====

function stmtCountWithChecker(input: string, setup: (cc: CheckerContext) => void): number {
	const result = parseInput(input);
	if (!result.ok) return -1;
	const cc = createContext();
	setup(cc);
	const tctx = createTransformContextWithChecker(cc);
	const lowered = lowerDCE(result.value, tctx);
	return getStmts(lowered).length;
}

// ===== Tests =====
test "passthrough unchanged" { expect(stmtCountAfter("const x = 1;", lowerDCE) === 1); }

test "strips after return" { expect(stmtCountAfter("return 1; const x = 2; const y = 3;", lowerDCE) === 1); }

test "strips after throw" { expect(stmtCountAfter("throw 1; const x = 2;", lowerDCE) === 1); }

test "hoisted function removed if unreferenced" {
	// Level 1 preserves hoisted decl, but Level 2 eliminates it (nobody calls helper)
	expect(stmtCountAfter("return 1; function helper() { return 2; }", lowerDCE) === 1);
}

test "hoisted class removed if unreferenced" { expect(stmtCountAfter("return 1; class Foo {}", lowerDCE) === 1); }

test "function body dead code removed" {
	// foo() call keeps the function alive; Level 1 strips dead const inside body
	expect(stmtCountAfter("function foo() { return 1; const dead = 2; } foo();", lowerDCE) === 2);
	expect(firstStmtKindAfter("function foo() { return 1; const dead = 2; } foo();", lowerDCE) === NodeKind.FunctionDecl);
}

test "if true keeps consequent" {
	expect(firstStmtKindAfter("if (true) { const x = 1; } else { const y = 2; }", lowerDCE) === NodeKind.BlockStmt);
	expect(stmtCountAfter("if (true) { const x = 1; } else { const y = 2; }", lowerDCE) === 1);
}

test "if false keeps alternate" { expect(firstStmtKindAfter("if (false) { const x = 1; } else { const y = 2; }", lowerDCE) === NodeKind.BlockStmt); }

test "if false no else becomes empty block" {
	expect(firstStmtKindAfter("if (false) { const x = 1; }", lowerDCE) === NodeKind.BlockStmt);
	expect(stmtCountAfter("if (false) { const x = 1; }", lowerDCE) === 1);
}

test "dynamic condition preserved" { expect(firstStmtKindAfter("if (x) { const a = 1; }", lowerDCE) === NodeKind.IfStmt); }

test "while false removed" { expect(firstStmtKindAfter("while (false) { doWork(); }", lowerDCE) === NodeKind.BlockStmt); }

test "while true preserved" { expect(firstStmtKindAfter("while (true) { break; }", lowerDCE) === NodeKind.WhileStmt); }

test "if-else both return strips after" { expect(stmtCountAfter("if (x) { return 1; } else { return 2; } const dead = 3;", lowerDCE) === 1); }

test "if-else one branch falls through keeps after" { expect(stmtCountAfter("if (x) { return 1; } else { const y = 2; } const alive = 3;", lowerDCE) === 2); }

test "if without else keeps after" { expect(stmtCountAfter("if (x) { return 1; } const alive = 2;", lowerDCE) === 2); }

test "nested if-else both return" {
	const code = "if (a) { if (b) { return 1; } else { return 2; } } else { return 3; } const dead = 4;";
	expect(stmtCountAfter(code, lowerDCE) === 1);
}

test "block ending in return" { expect(stmtCountAfter("{ return 1; } const dead = 2;", lowerDCE) === 1); }

test "block not ending in return" { expect(stmtCountAfter("{ const x = 1; } const alive = 2;", lowerDCE) === 2); }

test "throw in both if branches" { expect(stmtCountAfter("if (x) { throw 1; } else { throw 2; } const dead = 3;", lowerDCE) === 1); }

test "else-if chain all return" {
	const code = "if (a) { return 1; } else if (b) { return 2; } else { return 3; } const dead = 4;";
	expect(stmtCountAfter(code, lowerDCE) === 1);
}

test "else-if chain missing else" {
	const code = "if (a) { return 1; } else if (b) { return 2; } const alive = 3;";
	expect(stmtCountAfter(code, lowerDCE) === 2);
}

test "never call strips after" {
	const count = stmtCountWithChecker("fail(); const dead = 2;", (cc: CheckerContext) => {
		const fnType = createFunction([], [], neverType());
		const sym = makeSymbol("fail", SymbolKind.Function, fnType, false);
		defineSymbol(cc.table, sym);
	});
	expect(count === 1);
}

test "void call keeps after" {
	const count = stmtCountWithChecker("log(); const alive = 2;", (cc: CheckerContext) => {
		const fnType = createFunction([], [], voidType());
		const sym = makeSymbol("log", SymbolKind.Function, fnType, false);
		defineSymbol(cc.table, sym);
	});
	expect(count === 2);
}

test "unknown function keeps after" {
	// No symbol registered — conservative, keeps code
	const count = stmtCountWithChecker("mystery(); const alive = 2;", (cc: CheckerContext) => {});
	expect(count === 2);
}

test "null checker graceful" {
	// stmtCountAfter uses null checkerCtx — must not crash
	expect(stmtCountAfter("foo(); const alive = 2;", lowerDCE) === 2);
}

test "unused function removed" { expect(stmtCountAfter("function unused() {} const x = 1;", lowerDCE) === 1); }

test "used function kept" { expect(stmtCountAfter("function add(a, b) { return 1; } add(1, 2);", lowerDCE) === 2); }

test "exported function always kept" { expect(stmtCountAfter("export function api() { return 1; }", lowerDCE) === 1); }

test "mutual recursion both dead" { expect(stmtCountAfter("function a() { b(); } function b() { a(); }", lowerDCE) === 0); }

test "mutual recursion alive via call" { expect(stmtCountAfter("function a() { b(); } function b() { a(); } a();", lowerDCE) === 3); }

test "unused class removed" { expect(stmtCountAfter("class Dead {} const x = 1;", lowerDCE) === 1); }

test "used class kept" { expect(stmtCountAfter("class Alive {} const x = Alive;", lowerDCE) === 2); }

test "transitive liveness" { expect(stmtCountAfter("function helper() { return 1; } function api() { return helper(); } api();", lowerDCE) === 3); }

test "unused enum removed" { expect(stmtCountAfter("enum Color { Red, Green } const x = 1;", lowerDCE) === 1); }

test "variable decl always kept" {
	// Variable declarations have side effects (initializer runs)
	expect(stmtCountAfter("const x = 1;", lowerDCE) === 1);
}

test "isAlive false for empty" {
	const syms = createAliveSyms();
	expect(!isAlive(syms, "anything"));
}

test "markAlive then isAlive" {
	const syms = createAliveSyms();
	markAlive(syms, "foo");
	expect(isAlive(syms, "foo"));
	expect(!isAlive(syms, "bar"));
}
