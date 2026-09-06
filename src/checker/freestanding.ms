// Freestanding-runtime diagnostics — FREESTANDING E01.
//
// The freestanding runtime (`--gc=manual`, forced by `--os=bare` and
// `--os=solana`) has no dispatcher, no thread pool and no await slots:
// runtime/manual.h REPLACES runtime/core/system.h (it reuses its include
// guard) and stubs the future machinery, so an emitted `await` / `spawn`
// reaches clang as a wall of undeclared symbols — msAwaitSlotCreate,
// msAwaitSlotWait, msFutureCreate, msBoxInt32, msFutureCompleteT. Those
// cannot be stubbed no-op: msAwaitSlotWait has to park for real.
//
// One detector, two consumers, one wording:
//   - the compiler reports each site as an ERROR (it knows the real target),
//   - the LSP reports it as a WARNING (its target comes from build.ms `lsp`).
//
// Scope is deliberately narrow: async function declarations, `await`
// expressions, `spawn(...)` calls. Timers (sleepAsync) and the rest of
// std/promise are only observable through one of those three, so widening
// the surface would only duplicate diagnostics.

import { Node, NodeKind, SourceLocation, FunctionDeclData, FunctionExprData, ArrowFunctionData, MethodDeclData, createNodeAt, makeLoc } from "../ast/node";
import { forEachChild } from "../ast/visitor";

// Single wording shared by both consumers — only the severity differs.
export const FREESTANDING_ASYNC_MSG: string = "async/await is unsupported under the freestanding runtime (gc=manual): no dispatcher, no thread pool, no await slots (FREESTANDING E01)";

// Mirrors checkExprPass's isAsync test (fnFlags is a free-form flag string,
// "async" / "async_generator" / combinations).
function flagsAreAsync(flags: string): boolean {
	if (flags === "") return false;
	return flags.indexOf("async") >= 0;
}

// Function-like nodes own a scope for the one-diagnostic-per-body rule.
function isFunctionLike(node: Node): boolean {
	return node.kind === NodeKind.FunctionDecl
		|| node.kind === NodeKind.FunctionExpr
		|| node.kind === NodeKind.ArrowFunction
		|| node.kind === NodeKind.MethodDecl;
}

// `async` on the declaration itself.
export function isAsyncFunctionNode(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.FunctionDecl) return flagsAreAsync((node.data as FunctionDeclData).fnFlags);
	if (node.kind === NodeKind.FunctionExpr) return flagsAreAsync((node.data as FunctionExprData).funcExprFlags);
	if (node.kind === NodeKind.ArrowFunction) return flagsAreAsync((node.data as ArrowFunctionData).arrowFlags);
	if (node.kind === NodeKind.MethodDecl) return flagsAreAsync((node.data as MethodDeclData).methodFlags);
	return false;
}

// `spawn(thunk)` — recognised through the resolved builtin, same hook
// detectSequentialAwaitSpawn uses. Actor spawn goes through the same thunk.
export function isSpawnCall(node: Node): boolean {
	if (node === null || node.kind !== NodeKind.CallExpr) return false;
	if (node.resolvedSym === null) return false;
	return node.resolvedSym.builtinKind === "PromiseSpawn";
}

// Is this node an async surface the freestanding runtime cannot carry?
export function isFreestandingAsyncNode(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.AwaitExpr) return true;
	if (isSpawnCall(node)) return true;
	return isAsyncFunctionNode(node);
}

// Report position: declarations point at the name, expressions at themselves.
export function freestandingAsyncLoc(node: Node): SourceLocation {
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.nameLocation !== null) return d.nameLocation;
	}
	if (node.kind === NodeKind.MethodDecl) {
		const m = node.data as MethodDeclData;
		if (m.nameLocation !== null) return m.nameLocation;
	}
	return node.location;
}

// One report per function body: a single async function with ten awaits is one
// problem, not eleven. Interface (reference type) so the forEachChild closure
// mutates the caller's state.
interface FsScope {
	reported: boolean;
}

function fsWalk(node: Node, out: Node[], scope: FsScope): void {
	if (node === null) return;

	if (isFunctionLike(node)) {
		// A nested function starts its own report budget; the `async` keyword on
		// the declaration is that budget's first (and best-located) report.
		const inner: FsScope = { reported: false };
		if (isAsyncFunctionNode(node)) {
			out.push(node);
			inner.reported = true;
		}
		forEachChild(node, (child: Node): void => { fsWalk(child, out, inner); });
		return;
	}

	if (!scope.reported && isFreestandingAsyncNode(node)) {
		out.push(node);
		scope.reported = true;
	}
	forEachChild(node, (child: Node): void => { fsWalk(child, out, scope); });
}

// Collect the async sites of one module, deduped per function body.
// Empty result = nothing in this module needs a dispatcher.
export function collectFreestandingAsync(program: Node): Node[] {
	const out: Node[] = [];
	if (program === null) return out;
	const root: FsScope = { reported: false };
	fsWalk(program, out, root);
	return out;
}

// ===== Tests =====
// Hand-built AST: this module must not import the parser (it is consumed by
// both the checker-side gate and the LSP handler).

function fsLoc(): SourceLocation {
	return makeLoc(1, 1);
}

function fsBlock(stmts: Node[]): Node {
	return createNodeAt(NodeKind.BlockStmt, { statements: stmts }, fsLoc());
}

function fsIdent(name: string): Node {
	return createNodeAt(NodeKind.Identifier, { name }, fsLoc());
}

function fsAwait(): Node {
	const arg = fsIdent("p");
	return createNodeAt(NodeKind.AwaitExpr, { awaitArg: arg }, fsLoc());
}

function fsExprStmt(e: Node): Node {
	return createNodeAt(NodeKind.ExprStmt, { expr: e }, fsLoc());
}

function fsFn(name: string, flags: string, body: Node): Node {
	const params: string[] = [];
	const paramTypes: string[] = [];
	const defaults: Node[] = [];
	return createNodeAt(NodeKind.FunctionDecl, { fnName: name, params, fnParamTypes: paramTypes, fnBody: body, fnFlags: flags, fnReturnType: "", fnDefaults: defaults, nativeName: "", nameLocation: fsLoc() }, fsLoc());
}

function fsProgram(stmts: Node[]): Node {
	return createNodeAt(NodeKind.Program, { programStmts: stmts }, fsLoc());
}

test "freestanding: async declaration is one report" {
	const body = fsBlock([]);
	const fn = fsFn("f", "async", body);
	const prog = fsProgram([fn]);
	const hits = collectFreestandingAsync(prog);
	assert hits.length === 1;
	assert hits[0].kind === NodeKind.FunctionDecl;
}

test "freestanding: await in a sync body is reported" {
	const body = fsBlock([fsExprStmt(fsAwait())]);
	const fn = fsFn("f", "", body);
	const prog = fsProgram([fn]);
	assert collectFreestandingAsync(prog).length === 1;
}

test "freestanding: many awaits in one body collapse to one report" {
	const body = fsBlock([fsExprStmt(fsAwait()), fsExprStmt(fsAwait()), fsExprStmt(fsAwait())]);
	const fn = fsFn("f", "async", body);
	const prog = fsProgram([fn]);
	assert collectFreestandingAsync(prog).length === 1;
}

test "freestanding: each function body gets its own report" {
	const a = fsFn("a", "async", fsBlock([]));
	const b = fsFn("b", "async", fsBlock([]));
	const prog = fsProgram([a, b]);
	assert collectFreestandingAsync(prog).length === 2;
}

test "freestanding: top-level await is reported outside any function" {
	const prog = fsProgram([fsExprStmt(fsAwait())]);
	assert collectFreestandingAsync(prog).length === 1;
}

test "freestanding: synchronous program reports nothing" {
	const fn = fsFn("f", "", fsBlock([fsExprStmt(fsIdent("x"))]));
	const prog = fsProgram([fn]);
	assert collectFreestandingAsync(prog).length === 0;
}

test "freestanding: report position is the declaration name" {
	const fn = fsFn("f", "async", fsBlock([]));
	const loc = freestandingAsyncLoc(fn);
	assert loc.line === 1;
	assert loc.column === 1;
}
