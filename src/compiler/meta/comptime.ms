// ComptimeEval — Evaluate @comptime blocks via Raiser VM, fold results into AST
//
// This module is the consumer side of the macro-system bridge:
//   1. Walks the AST looking for ComptimeBlock nodes
//   2. For each one: extracts the body, runs it in the Raiser VM
//   3. Converts the VM's result back to an AST literal node
//   4. Replaces the ComptimeBlock with the result
//
// All the Node ↔ RaiserValue serialization lives in src/compiler/meta/bridge.ms
// (also used by the future macro expansion pass).

import {
	Node, NodeKind, createNode,
	VariableDeclData, FunctionDeclData,
	ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	BlockStmtData, ExportDeclData,
	ComptimeBlockData, ProgramData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	Type,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/checkPass";
import { evalASTFull, evalProgramViaEngine } from "../../codegen/raiser/eval";
import {
	clearObjectHeap, clearArrayHeap, RaiserValueKind,
} from "../../raiser/value";
import { RaiserContext } from "../../raiser/context";
import { valueToNode, synthToken } from "./bridge";
import { ensureHostTableLoaded } from "./hostTable";
import { CheckerContext, addError } from "../../checker/context";

// --- Evaluate a single ComptimeBlock node ---
// Exported so the checker can eagerly fold @comptime blocks during type
// checking (mirrors Phase B+ macro eager expansion). Without eager folding,
// `const X = @comptime { ... }` fossilizes the variable's symbol type as
// `unknown` (checker doesn't know the block's result type yet), which then
// emits `void* X = ...` in C codegen — see checkExprPass.ms ComptimeBlock
// handler. Also keeps `evaluateComptimeBlocks` as a safety net for blocks
// introduced by transforms after checking.

export function evalComptimeBlock(node: Node, checkerCtx: CheckerContext): Node {
	// Populate the host-call registry on first use. Idempotent — subsequent
	// @comptime blocks reuse the same registry without re-registering.
	ensureHostTableLoaded();

	const d = node.data as ComptimeBlockData;
	const body = d.comptimeBody;
	const loc = node.location;

	// Extract statements from the body block
	const bodyData = body.data as BlockStmtData;
	const stmts = bodyData.statements;

	// Transform last ExprStmt into ReturnStmt so the VM captures the value
	// (standard comptime/REPL semantics — implicit return of last expression)
	const finalStmts: Node[] = [];
	let si = 0;
	while (si < stmts.length) {
		if (si === stmts.length - 1 && stmts[si].kind === NodeKind.ExprStmt) {
			const ed = stmts[si].data as ExprStmtData;
			finalStmts.push(createNode(NodeKind.ReturnStmt, { argument: ed.expr }, synthToken(loc)));
		} else {
			finalStmts.push(stmts[si]);
		}
		si = si + 1;
	}

	// Engine path (checkerCtx present): seeds + on-demand compile via the
	// shared comptime image (NIM-REF §1 CT-eval). Standalone fallback
	// (no ctx, e.g. evaluateComptimeBlocks): top-level statements, body
	// must be self-contained.
	let ctx: RaiserContext | null;
	if (checkerCtx !== null) {
		const fnBody = createNode(NodeKind.BlockStmt, { statements: finalStmts }, synthToken(loc));
		const emptyDefaults: Node[] = [];
		const comptimeFn = createNode(NodeKind.FunctionDecl, {
			fnName: "__comptimeBody",
			params: [],
			fnParamTypes: [],
			fnBody: fnBody,
			fnFlags: "",
			fnReturnType: "",
			fnDefaults: emptyDefaults,
			nameLocation: loc,
		}, synthToken(loc));
		const program = createNode(NodeKind.Program, { programStmts: [comptimeFn] }, synthToken(loc));
		ctx = evalProgramViaEngine(program, checkerCtx, "__comptimeBody");
	} else {
		const program = createNode(NodeKind.Program, { programStmts: finalStmts }, synthToken(loc));
		ctx = evalASTFull(program);
	}

	// Loud-error propagation: if the VM halted with an error (e.g. unknown
	// host function — missing extern bridge in hostTable.ms), surface as a
	// compile error tied to the @comptime block location. Without this, the
	// VM silently sets ctx.lastResult = Nil and `valueToNode` folds it to
	// `null`, which then hits a confusing "Type 'null' is not assignable to
	// type 'X'" error far from the actual cause. The most common cause is a
	// missing string/array extension method bridge.
	if (ctx.lastError !== "" && checkerCtx !== null) {
		addError(checkerCtx, "@comptime evaluation failed: " + ctx.lastError, loc.line, loc.column);
	}

	// Convert VM result back to an AST literal
	const result = valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);

	// Reclaim VM heaps — prevents monotonic growth during long builds
	clearObjectHeap(ctx.objectHeap);
	clearArrayHeap(ctx.arrayHeap);
	ctx = null;

	return result;
}

// --- First pass: check if AST contains any ComptimeBlock nodes ---

function hasComptimeBlock(node: Node): boolean {
	if (node === null) return false;
	return match (node.kind) {
		NodeKind.ComptimeBlock => true,
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			return hasComptimeBlock(d.initializer);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			return hasComptimeBlock(d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			return hasComptimeBlock(d.argument);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) {
				if (hasComptimeBlock(stmt)) return true;
			}
			return false;
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			return hasComptimeBlock(d.exportedDecl);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			return hasComptimeBlock(d.fnBody);
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const stmt of d.programStmts) {
				if (hasComptimeBlock(stmt)) return true;
			}
			return false;
		},
		_ => false,
	};
}

// --- AST walker — find and replace ComptimeBlock nodes ---

function walkNode(node: Node): Node {
	return match (node.kind) {
		NodeKind.ComptimeBlock => evalComptimeBlock(node, null as unknown as CheckerContext),
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			const newInit = walkNode(d.initializer);
			return createNode(NodeKind.VariableDecl, {
				declName: d.declName, declType: d.declType,
				initializer: newInit, declKind: d.declKind,
				nameLocation: d.nameLocation,
			}, synthToken(node.location));
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			const newExpr = walkNode(d.expr);
			return createNode(NodeKind.ExprStmt, { expr: newExpr }, synthToken(node.location));
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			const newArg = walkNode(d.argument);
			return createNode(NodeKind.ReturnStmt, { argument: newArg }, synthToken(node.location));
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			const newStmts: Node[] = [];
			let i = 0;
			while (i < d.statements.length) {
				newStmts.push(walkNode(d.statements[i]));
				i = i + 1;
			}
			return createNode(NodeKind.BlockStmt, { statements: newStmts }, synthToken(node.location));
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			const newBody = walkNode(d.fnBody);
			return createNode(NodeKind.FunctionDecl, {
				fnName: d.fnName, params: d.params, fnParamTypes: d.fnParamTypes,
				fnBody: newBody, fnFlags: d.fnFlags, fnReturnType: d.fnReturnType,
				fnDefaults: d.fnDefaults, nameLocation: d.nameLocation,
			}, synthToken(node.location));
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			const newCons = walkNode(d.consequent);
			const newAlt = walkNode(d.alternate);
			return createNode(NodeKind.IfStmt, {
				condition: d.condition, consequent: newCons, alternate: newAlt,
			}, synthToken(node.location));
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			const newBody = walkNode(d.whileBody);
			return createNode(NodeKind.WhileStmt, {
				whileCondition: d.whileCondition, whileBody: newBody,
			}, synthToken(node.location));
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			const newDecl = walkNode(d.exportedDecl);
			return createNode(NodeKind.ExportDecl, { exportedDecl: newDecl }, synthToken(node.location));
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			const newStmts: Node[] = [];
			let i = 0;
			while (i < d.programStmts.length) {
				newStmts.push(walkNode(d.programStmts[i]));
				i = i + 1;
			}
			return createNode(NodeKind.Program, { programStmts: newStmts }, synthToken(node.location));
		},
		_ => node,
	};
}

// --- Public API ---

export function evaluateComptimeBlocks(program: Node): Node {
	if (!hasComptimeBlock(program)) return program;
	return walkNode(program);
}

// Register evalComptimeBlock as a callback so checkExprPass can invoke it
// without importing this module directly (breaks the checker ↔ compiler/meta cycle).
import { registerEvalComptimeBlock } from "../../checker/checkerCallbacks";
registerEvalComptimeBlock(evalComptimeBlock);

// --- E2E Comptime Tests ---

test "comptime int arithmetic" {
	const pr = parseSource("const VERSION = @comptime { 10 + 5 };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	assert varDecl.kind === NodeKind.VariableDecl;
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NumberLiteral;
	const nd = vd.initializer.data as NumberLiteralData;
	assert nd.value === 15;
}

test "comptime string" {
	const pr = parseSource("const PLATFORM = @comptime { \"darwin\" };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.StringLiteral;
	const sd = vd.initializer.data as StringLiteralData;
	assert sd.value === "darwin";
}

test "comptime boolean" {
	const pr = parseSource("const DEBUG = @comptime { true };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.BooleanLiteral;
	const bd = vd.initializer.data as BooleanLiteralData;
	assert bd.boolValue === true;
}

test "no comptime passes through" {
	const pr = parseSource("const x = 42;");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	assert result === pr.value;
}

// --- Phase 8a POC regression tests (same-file outer-scope @comptime) ---
// These exercise the engine path in evalComptimeBlock by going through
// the full eager-fold via checkProgram (which sets the outer-program slot).
// Each test parses a complete module with module-level decls + a @comptime
// block that calls those decls, then asserts the fold result is a literal.

import { checkProgram } from "../../checker/checkPass";

test "Phase 8a: outer fn callable from @comptime" {
	const pr = parseSource(
		"function dbl(x: number): number { return x * 2; }" +
		"const Y = @comptime { dbl(21) };"
	);
	assert pr.ok;
	checkProgram(pr.value);  // eager-folds the @comptime block
	const pd = pr.value.data as ProgramData;
	// programStmts[0] = function decl, [1] = const decl with folded literal
	const varDecl = pd.programStmts[1];
	assert varDecl.kind === NodeKind.VariableDecl;
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NumberLiteral;
	const nd = vd.initializer.data as NumberLiteralData;
	assert nd.value === 42;
}

test "Phase 8a: outer fn chain (transitive same-file)" {
	const pr = parseSource(
		"function inc(x: number): number { return x + 1; }" +
		"function dbl(x: number): number { return inc(x) * 2; }" +
		"const Z = @comptime { dbl(5) };"
	);
	assert pr.ok;
	checkProgram(pr.value);
	const pd = pr.value.data as ProgramData;
	const varDecl = pd.programStmts[2];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NumberLiteral;
	const nd = vd.initializer.data as NumberLiteralData;
	assert nd.value === 12;  // (5+1)*2
}

test "Phase 8a: outer fn + extern via CallHost" {
	const pr = parseSource(
		"extern function msFsExists(path: string): number;" +
		"function bothExist(a: string, b: string): number {" +
		"  return msFsExists(a) + msFsExists(b);" +
		"}" +
		"const N = @comptime { bothExist(\"README.md\", \"/tmp/__missing_xyz__\") };"
	);
	assert pr.ok;
	checkProgram(pr.value);
	const pd = pr.value.data as ProgramData;
	const varDecl = pd.programStmts[2];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NumberLiteral;
	const nd = vd.initializer.data as NumberLiteralData;
	assert nd.value === 1;  // README exists (1) + missing (0)
}

// Single-file checkProgram mode has no outer ExportRegistry, so cross-module
// import inside @comptime returns Nil. Production path uses checkProgramWithRegistry
// (orchestrator) which DOES set the registry; cross-module then works end-to-end.
// Verified via `msc run`:
//   import { exec } from "std/process";
//   const VERSION = @comptime { exec("echo v1.2.3").value };
//   → VERSION = "v1.2.3\n" baked into binary
test "Phase 8b: cross-module unresolved in single-file mode (no registry)" {
	const pr = parseSource(
		"import { dirname } from \"std/fs\";" +
		"const D = @comptime { dirname(\"/a/b/c\") };"
	);
	assert pr.ok;
	checkProgram(pr.value);
	const pd = pr.value.data as ProgramData;
	const varDecl = pd.programStmts[1];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NullLiteral;
}

// --- CallHost smoke tests (Phase 6) ---
// End-to-end: parse → check → transform → Raiser codegen (emits CallHost
// from resolved extern Symbol) → VM dispatch → registered bridge → MS-level
// std fn → result folded into AST literal.
//
// Each test asserts the @comptime block folds to the expected literal kind,
// proving the entire CallHost pipeline works from user source to value.

// Smoke helper: parse a self-contained MS program (extern + call) and run
// it through the full Raiser pipeline. This bypasses @comptime block AST
// surgery and tests the CallHost path end-to-end: parse → check → transform
// → codegen (emits CallHost from resolvedSym.nativeName) → VM dispatch →
// registered bridge → MS host fn.

function _smokeCallHost(src: string): RaiserContext {
	ensureHostTableLoaded();
	const pr = parseSource(src);
	if (!pr.ok) {
		unreachable;
		return null as unknown as RaiserContext;
	}
	return evalASTFull(pr.value);
}

test "comptime CallHost msProcessPlatform" {
	const ctx = _smokeCallHost("extern function msProcessPlatform(): string; return msProcessPlatform();");
	assert ctx.lastError === "";
	assert ctx.lastResult.kind === RaiserValueKind.String;
	assert ctx.lastResult.strVal.length > 0;
}

test "comptime CallHost msProcessCwd" {
	const ctx = _smokeCallHost("extern function msProcessCwd(): string; return msProcessCwd();");
	assert ctx.lastError === "";
	assert ctx.lastResult.kind === RaiserValueKind.String;
	assert ctx.lastResult.strVal.length > 0;
}

test "comptime CallHost msFsExists present file" {
	const ctx = _smokeCallHost("extern function msFsExists(path: string): number; return msFsExists(\"README.md\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal === 1;
}

test "comptime CallHost msFsExists missing file" {
	const ctx = _smokeCallHost("extern function msFsExists(path: string): number; return msFsExists(\"/tmp/__nope_xyz__\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal === 0;
}

test "comptime CallHost msFsIsFile README" {
	const ctx = _smokeCallHost("extern function msFsIsFile(path: string): number; return msFsIsFile(\"README.md\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal === 1;
}

test "comptime CallHost msFsIsDir cwd" {
	const ctx = _smokeCallHost("extern function msFsIsDir(path: string): number; return msFsIsDir(\".\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal === 1;
}

test "comptime CallHost msFsFileSize positive" {
	const ctx = _smokeCallHost("extern function msFsFileSize(path: string): number; return msFsFileSize(\"README.md\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal > 0;
}

test "comptime CallHost msProcessGetEnv missing var" {
	const ctx = _smokeCallHost("extern function msProcessGetEnv(name: string): string; return msProcessGetEnv(\"__NEVER_SET_ABCXYZ__\");");
	assert ctx.lastError === "";
	assert ctx.lastResult.kind === RaiserValueKind.String;
	assert ctx.lastResult.strVal === "";
}

// Pure-MS test (no CallHost) — verifies the smoke harness compiles plain MS
// correctly so any CallHost failures aren't masked by harness issues.
test "comptime smoke harness pure MS" {
	const ctx = _smokeCallHost("function add(a: number, b: number): number { return a + b; } return add(10, 32);");
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal === 42;
}

// --- Phase 7 smoke tests: wrapper-inline pattern ---
// Each test inlines an MS wrapper that mirrors what std/fs / std/process
// provide, exercising the full chain: extern decl → MS wrapper body
// (compiled to bytecode) → CallHost → bridge → host shim → return.
//
// Demonstrates the "Nim trick": Raiser compiles pure-MS wrapper bodies
// to bytecode and executes them in-VM, with C natives bridged out via
// CallHost. The Result-style return object is built by NewObject opcodes
// inside the VM — no heap-aware bridge needed.

test "comptime CallHost msFsReadFile reads README" {
	const ctx = _smokeCallHost(
		"extern function msFsReadFile(path: string): string;" +
		"return msFsReadFile(\"README.md\");"
	);
	assert ctx.lastError === "";
	assert ctx.lastResult.kind === RaiserValueKind.String;
	assert ctx.lastResult.strVal.length > 0;
}

test "comptime CallHost msFsReadFile missing → empty + errno set" {
	const ctx = _smokeCallHost(
		"extern function msFsReadFile(path: string): string;" +
		"extern function msFsLastErrno(): number;" +
		"const raw = msFsReadFile(\"/tmp/__missing_zzz__\");" +
		"return msFsLastErrno();"
	);
	assert ctx.lastError === "";
	assert ctx.lastResult.intVal !== 0;
}

test "comptime CallHost wrapper-inline Result-like" {
	// Manually inline the readFile-as-Result pattern: extern + errno poll +
	// branch + Object construction. Mirrors std/fs.readFile body exactly.
	const ctx = _smokeCallHost(
		"extern function msFsReadFile(path: string): string;" +
		"extern function msFsLastErrno(): number;" +
		"interface FileRes { ok: boolean; value: string; err: number; }" +
		"function tryRead(path: string): FileRes {" +
		"  const raw = msFsReadFile(path);" +
		"  const e = msFsLastErrno();" +
		"  if (e !== 0) return { ok: false, value: \"\", err: e };" +
		"  return { ok: true, value: raw, err: 0 };" +
		"}" +
		"return tryRead(\"README.md\");"
	);
	assert ctx.lastError === "";
	// Result is a heap-allocated Object inside the VM
	assert ctx.lastResult.kind === RaiserValueKind.Object;
}

test "comptime CallHost msFsReadDirEntries non-empty" {
	const ctx = _smokeCallHost(
		"extern function msFsReadDirEntries(path: string): string;" +
		"return msFsReadDirEntries(\".\");"
	);
	assert ctx.lastError === "";
	assert ctx.lastResult.kind === RaiserValueKind.String;
	assert ctx.lastResult.strVal.length > 0;
}

// --- The real test: import std/fs.readFile (NOT an inline extern) ---
// User actually writes: `import { readFile } from "std/fs"` and calls it
// from @comptime. The chain is:
//   readFile (MS wrapper in std/fs)
//     → msFsReadFile (extern, → CallHost → bridge)
//     → msFsLastErrno (extern, → CallHost → bridge)
//     → Result.ok(raw) / Result.err(...) (builtinLower → ObjectLiteral)
// For this to work, Raiser codegen must be able to COMPILE the body of
// readFile (which lives in std/fs) — i.e., it needs cross-module resolution.

// Production usage anh sẽ viết:
//
//     import { readFile } from "std/fs";          // module-level
//     const CFG = @comptime { readFile("config.json") };
//
// Verify path này CHƯA test được trong session vì smoke helper _smokeCallHost
// bypasses @comptime block extraction.
// → Real cross-module @comptime usage = UNVERIFIED (Phase 8a).
