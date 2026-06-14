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
	BlockStmtData, ExportDeclData, DecoratedDeclData, ExternDeclData,
	ComptimeBlockData, ProgramData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	ImportDeclData, CallExprData, IdentifierData, Type,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/checkPass";
import { evalASTFull } from "../../codegen/raiser/eval";
import {
	clearObjectHeap, clearArrayHeap, RaiserValueKind,
} from "../../raiser/value";
import { RaiserContext } from "../../raiser/context";
import { valueToNode, synthToken } from "./bridge";
import { ensureHostTableLoaded } from "./hostTable";
import { getComptimeOuterCtx } from "./callbacks";
import { findExportsByName, ExportRegistry, CheckerContext, addError } from "../../checker/context";
import { lookupModuleProgram } from "../../checker/instantiate";
import { forEachChild } from "../../ast/visitor";
import { isPrimitiveKind } from "../../checker/types";

// --- Phase 8a POC helpers ---
// Decides which outer top-level decls get injected into the synthetic
// Program before evalASTFull. Kept narrow on purpose — extending the
// filter widens the surface area for AST-mutation drift (see CAVEAT in
// evalComptimeBlock). Phase 8b refactor will replace with on-demand
// resolution via ExportRegistry.

function _isInjectableTopLevelDecl(stmt: Node): boolean {
	if (stmt.kind === NodeKind.FunctionDecl) return true;
	if (stmt.kind === NodeKind.ImportDecl) return true;
	return false;
}

// Spike 2 step 2: walk outer ImportDecls, resolve each imported name via
// the outer ExportRegistry, and return the cross-module FunctionDecl AST
// nodes so they can be injected into the synthetic Program (where Raiser
// codegen's Pass 1 collection will register them, and Pass 2 will compile
// their bodies into bytecode).
//
// Transitive deps (helpers called inside an injected fn body that aren't
// exported) are NOT collected here yet — Phase 8b-iii.

// Exported so macro path (src/compiler/meta/expand.ms) can reuse the same
// cross-module callee resolution that @comptime uses. Macro wrapper Program
// must include helper FunctionDecls or cross-module calls return nil
// (RAISER-CALLHOST.md Phase 8a caveat #5).

// Find a callable declaration (FunctionDecl or ExternDecl) by name in a
// module's top-level statements. Handles bare + ExportDecl-wrapped +
// DecoratedDecl-wrapped forms. Returns null if not found. Shared between
// the @comptime cross-module injector (here) and the macro cross-module
// injector (expand.ms).
export function findFunctionDeclInProgram(program: Node, name: string): Node {
	if (program === null || program.kind !== NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		const fd = unwrapToCallableDecl(stmt, name);
		if (fd !== null) return fd;
	}
	return null as unknown as Node;
}

function unwrapToCallableDecl(stmt: Node, name: string): Node {
	if (stmt === null) return null as unknown as Node;
	return match (stmt.kind) {
		NodeKind.FunctionDecl => (stmt.data as FunctionDeclData).fnName === name ? stmt : null as unknown as Node,
		NodeKind.ExternDecl => (stmt.data as ExternDeclData).externName === name ? stmt : null as unknown as Node,
		NodeKind.ExportDecl => unwrapToCallableDecl((stmt.data as ExportDeclData).exportedDecl, name),
		NodeKind.DecoratedDecl => unwrapToCallableDecl((stmt.data as DecoratedDeclData).decoratedNode, name),
		_ => null as unknown as Node,
	};
}

export function lookupFunctionDeclByName(registry: ExportRegistry, name: string): Node {
	// Returns first callable AST decl (FunctionDecl or ExternDecl variant
	// like `extern class`) matching `name`. `extern function` is parsed as
	// FunctionDecl with extern flag, so the FunctionDecl branch covers it.
	// ExternDecl is reserved for the other extern kinds (class/const/var/
	// type/enum/interface/struct/macro — parseExternDecl).
	//
	// NOTE: scans ALL modules with that name. If two modules export the
	// same name, picks first match — may pick wrong decl when names collide.
	// Phase 8b follow-up: resolve through ModuleGraph for disambiguation.
	// For std/* surface (no name collisions today) this is unambiguous enough.
	//
	// Fallback path: ExportRegistry's Phase 1 placeholder leaves declNode=null
	// (filled in by Phase 2 buildExportInfo). When @comptime eager-folds during
	// Phase 2 checking and the defining module's Phase 2 update hasn't run yet,
	// declNode is still null. Recover by walking the module's registered Program
	// AST — Program is registered during Phase 1 (orchestrator.ms), so it's
	// always available before any @comptime in any module fires.
	const matches = findExportsByName(registry, name);
	for (const expInfo of matches) {
		if (expInfo.declNode !== null && expInfo.declNode.kind === NodeKind.FunctionDecl) {
			return expInfo.declNode;
		}
	}
	for (const expInfo of matches) {
		if (expInfo.definingModule === "") continue;
		const prog = lookupModuleProgram(expInfo.definingModule);
		if (prog === null) continue;
		const fd = findFunctionDeclInProgram(prog, name);
		if (fd !== null) return fd;
	}
	return null as unknown as Node;
}

// Walk a body AST recursively, find CallExpr → Identifier patterns, and
// follow each name into the registry. Any imported FunctionDecls reached
// transitively are added to the worklist. Cycle-safe via the visited set
// keyed on function name.
//
// Exported for macro path reuse (see lookupFunctionDeclByName note).
export function walkBodyForCallees(
	body: Node, registry: ExportRegistry, definingProgram: Node, visited: HashSet<string>, queue: Node[],
): void {
	if (body === null) return;
	if (body.kind === NodeKind.CallExpr) {
		const c = body.data as CallExprData;
		if (c.callee !== null && c.callee.kind === NodeKind.Identifier) {
			const name = (c.callee.data as IdentifierData).name;
			if (!visited.has(name)) {
				visited.add(name);
				// Try defining module's Program FIRST — catches PRIVATE helpers
				// and `extern function` decls (parsed as FunctionDecl, not exported
				// so registry.nameIndex misses them). Mirrors expand.ms macro path.
				let fnDecl: Node = null as unknown as Node;
				if (definingProgram !== null) {
					fnDecl = findFunctionDeclInProgram(definingProgram, name);
				}
				if (fnDecl === null) fnDecl = lookupFunctionDeclByName(registry, name);
				if (fnDecl !== null) queue.push(fnDecl);
			}
		}
	}
	forEachChild(body, (child: Node) => {
		walkBodyForCallees(child, registry, definingProgram, visited, queue);
	});
}

// Phase 8c: walker that collects type-level decls (Interface/Enum/TypeAlias)
// reachable from injected FunctionDecls' signatures. Required for the inner
// check to resolve nested field access like `r.error.kind` where the field
// types live in cross-module type-level declarations.

function _collectTypeRefsFromType(t: Type, names: HashSet<string>): void {
	_collectTypeRefsFromTypeImpl(t, names, new HashSet<string>());
}

// Inner walker carries a per-top-level-call visited set keyed by typeName so
// self-referential types (e.g. interface Window { children: Window[] } or
// Result<T, E> wrappers reached transitively) don't recurse forever through
// typeChildren / typeReturn. Without this guard, importing parseJson into a
// module that exports an interface with a recursive field crashes the comptime
// VM with "Maximum call stack size exceeded" — the names HashSet alone does
// not block recursion because the primitive-kind check skips adding (and the
// caller pre-seeds it, so name presence does not imply "already walked").
function _collectTypeRefsFromTypeImpl(t: Type, names: HashSet<string>, visited: HashSet<string>): void {
	if (t === null) return;
	if (t.typeName !== "") {
		if (visited.has(t.typeName)) return;
		visited.add(t.typeName);
		// Skip primitive types by TypeKind (more robust than name matching —
		// reuses checker's canonical predicate and naturally excludes literal-
		// typed terms like the "true"/"false" disc values of match-type DUs).
		if (!isPrimitiveKind(t.kind)) names.add(t.typeName);
	}
	if (t.typeChildren !== null) {
		for (const c of t.typeChildren) {
			_collectTypeRefsFromTypeImpl(c, names, visited);
		}
	}
	if (t.typeReturn !== null) {
		_collectTypeRefsFromTypeImpl(t.typeReturn, names, visited);
	}
}

function _collectCrossModuleTypeDecls(fnDecls: Node[]): Node[] {
	// Seed: type names referenced in injected functions' signatures.
	// Process: for each name, look up registry → if Interface/Enum/TypeAlias,
	//          inject. Then walk THAT type's structure to find more refs.
	// Cycle-safe via `visited` set. Bounded by reachable type closure.
	const decls: Node[] = [];
	const outer = getComptimeOuterCtx();
	if (outer === null || outer.registry === null) return decls;
	const registry = outer.registry;

	const seedNames = new HashSet<string>();
	for (const fnDecl of fnDecls) {
		const sym = fnDecl.resolvedSym;
		if (sym !== null && sym.symbolType !== null) {
			_collectTypeRefsFromType(sym.symbolType, seedNames);
		}
	}

	const visited = new HashSet<string>();
	const queue: string[] = [];
	for (const name of seedNames) queue.push(name);

	while (queue.length > 0) {
		const name = queue.pop();
		if (visited.has(name)) continue;
		visited.add(name);

		const matches = findExportsByName(registry, name);
		for (const expInfo of matches) {
			// Two sources for the type-level AST:
			//   1. expInfo.declNode — populated only for safe-to-preserve kinds
			//      (EnumDecl). Direct path used when available.
			//   2. expInfo.symType.sym.declNode — Type.sym chain bridges to the
			//      defining module's symbol, whose declNode still points to the
			//      original AST. Used for Interface/TypeAlias which are NOT
			//      preserved in expInfo.declNode (would trigger ensureShaped
			//      cascade pollution; see buildExportInfo notes).
			let typeDecl: Node = null as unknown as Node;
			if (expInfo.declNode !== null
					&& (expInfo.declNode.kind === NodeKind.InterfaceDecl
						|| expInfo.declNode.kind === NodeKind.EnumDecl
						|| expInfo.declNode.kind === NodeKind.TypeAliasDecl)) {
				typeDecl = expInfo.declNode;
			} else if (expInfo.symType !== null && expInfo.symType.sym !== null
					&& expInfo.symType.sym.declNode !== null) {
				const tk = expInfo.symType.sym.declNode.kind;
				if (tk === NodeKind.InterfaceDecl || tk === NodeKind.EnumDecl
						|| tk === NodeKind.TypeAliasDecl) {
					typeDecl = expInfo.symType.sym.declNode;
				}
			}
			if (typeDecl === null) continue;
			decls.push(typeDecl);
			// Walk this type's structure for transitive refs (e.g., IoError
			// interface has field of type IoErrorKind).
			if (expInfo.symType !== null) {
				const moreNames = new HashSet<string>();
				_collectTypeRefsFromType(expInfo.symType, moreNames);
				for (const n of moreNames) {
					if (!visited.has(n)) queue.push(n);
				}
			}
			break;
		}
	}

	return decls;
}

function _collectCrossModuleFunctionDecls(outerProgram: Node, comptimeBody: Node): Node[] {
	// Phase 8b: walk outer ImportDecls, look up each imported name in the
	// outer ExportRegistry, and collect the cross-module FunctionDecl AST
	// nodes (plus transitive helpers their bodies call into) so Raiser
	// codegen can compile them into bytecode. Requires context.ms:
	// buildExportInfo to preserve declNode for ALL FunctionDecls.
	//
	// Also walks the @comptime body itself so names referenced there but not
	// imported by the outer module (e.g. `exec("…")` inside a module that
	// only imports unrelated symbols) still get their FunctionDecl injected.
	// Without this seed, the checker resolves them via the full registry but
	// Raiser codegen sees an unresolved Identifier → emits LoadConst(Nil) →
	// CallExpr falls into compileClosureCall → LoadField on Nil →
	// "object handle out of bounds: 0".
	const decls: Node[] = [];
	const outer = getComptimeOuterCtx();
	if (outer === null || outer.registry === null) return decls;
	const registry = outer.registry;
	const outerData = outerProgram.data as ProgramData;
	const visited = new HashSet<string>();
	const queue: Node[] = [];

	// Seed: directly-imported names.
	for (const stmt of outerData.programStmts) {
		if (stmt.kind !== NodeKind.ImportDecl) continue;
		const imp = stmt.data as ImportDeclData;
		for (const name of imp.importNames) {
			if (visited.has(name)) continue;
			visited.add(name);
			const fnDecl = lookupFunctionDeclByName(registry, name);
			if (fnDecl !== null) queue.push(fnDecl);
		}
	}

	// Seed: names referenced directly inside the @comptime body. Defining
	// program null — body lives in outer module which has its own decls
	// injected via _isInjectableTopLevelDecl path (FunctionDecl + ImportDecl).
	if (comptimeBody !== null) {
		walkBodyForCallees(comptimeBody, registry, null as unknown as Node, visited, queue);
	}

	// Transitive: drain queue, walk each body for further callees. For each
	// injected FunctionDecl, look up its defining module so the body walker
	// can resolve PRIVATE helpers and `extern function` decls (parsed as
	// FunctionDecl, not in registry because not exported). Without this,
	// e.g. exec() references msProcessSpawnSync which the registry doesn't
	// surface → re-check on synthetic Program can't resolve → silent Nil.
	while (queue.length > 0) {
		const decl = queue.pop();
		decls.push(decl);
		if (decl.kind !== NodeKind.FunctionDecl) continue;
		const fd = decl.data as FunctionDeclData;
		const matches = findExportsByName(registry, fd.fnName);
		let definingProgram: Node = null as unknown as Node;
		for (const m of matches) {
			if (m.definingModule === "") continue;
			const p = lookupModuleProgram(m.definingModule);
			if (p !== null) { definingProgram = p; break; }
		}
		walkBodyForCallees(fd.fnBody, registry, definingProgram, visited, queue);
	}

	return decls;
}

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

	// Inject outer module-level decls + cross-module FunctionDecls so the
	// @comptime body can reach functions across module boundaries. Bodies
	// are injected by reference (no clone); inner check mutates shared AST
	// — verified self-stable for happy-path symbol resolution.
	//
	// Known limitation: only FunctionDecl + ImportDecl injected. Cross-
	// module type-level decls (Interface/Enum/TypeAlias) NOT injected, so
	// nested access of imported types' fields (e.g., `r.error.kind` where
	// IoError is in std/io/errors) returns Nil. Workaround: avoid nested
	// access into imported error variants; restrict to `.value`/`.ok`.
	// Full fix requires proper type walker (start from injected fn return
	// types, walk type references, inject reached type decls) — separate
	// initiative.
	const injectedStmts: Node[] = [];
	const outerCtx = getComptimeOuterCtx();
	const outerProgram = outerCtx !== null ? outerCtx.program : null as unknown as Node;
	if (outerProgram !== null && outerProgram.kind === NodeKind.Program) {
		const outerData = outerProgram.data as ProgramData;
		for (const stmt of outerData.programStmts) {
			if (_isInjectableTopLevelDecl(stmt)) {
				injectedStmts.push(stmt);
			}
		}
		const crossModule = _collectCrossModuleFunctionDecls(outerProgram, body);
		for (const s of crossModule) { injectedStmts.push(s); }
		// Phase 8c: inject type-level decls (Interface/Enum/TypeAlias) reachable
		// from the injected fns' signatures, transitively. Required so the inner
		// check resolves nested field access like `r.error.kind` where IoError
		// (and its IoErrorKind enum) live in cross-module type-level decls. Walker
		// eliminates 9+ "Unresolved type 'IoError'" errors that otherwise flood
		// the inner check and break codegen for the @comptime body.
		const crossModuleTypes = _collectCrossModuleTypeDecls(crossModule);
		for (const s of crossModuleTypes) { injectedStmts.push(s); }
	}

	const allStmts: Node[] = [];
	for (const s of injectedStmts) { allStmts.push(s); }
	for (const s of finalStmts) { allStmts.push(s); }
	const program = createNode(NodeKind.Program, { programStmts: allStmts }, synthToken(loc));

	// Evaluate through the Raiser VM
	let ctx: RaiserContext | null = evalASTFull(program);

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
// These exercise the injection path in evalComptimeBlock by going through
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
// Verified via `bun run run-ms`:
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
// std fn (Bun shim today) → result folded into AST literal.
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
// Verify path này CHƯA test được trong session vì:
//   1. Smoke helper _smokeCallHost bypasses @comptime block extraction.
//   2. `bun run run-ms <file>` đang fail tại prelude std/serialize/json/decode.ms
//      (WIP của anh). Compiler không reach được test file.
// → Real cross-module @comptime usage = UNVERIFIED. Phase 8a hoặc anh fix
// prelude trước khi confirm được.
