// Destructor Lifting — generate per-type lifecycle hook function bodies
//
// Nim reference: liftdestructors.nim
//   fillBody()             — pure routing table (TypeKind → type family helper)
//   fillStrOp()            — string lifecycle
//   fillSeqOp()            — sequence/array lifecycle
//   atomicRefOp()          — ref/ptr lifecycle
//   closureOp()            — closure lifecycle
//   fillBodyObjT()         — value-type object lifecycle
//   fillBodyTup()          — tuple field iteration
//   considerUserDefinedOp  — user hook dispatch (onDestroy/onCopy/etc.)
//   cyclicType()           — cycle detection for ORC
//   checkSelfAssignment()  — early return on dest === src
//
// Generates up to 6 hooks per type + TypeInfo:
//   =destroy   TypeName_destroy(self)            — cleanup RC fields
//   =copy      TypeName_copy(dest, src)          — deep copy (assign + incref)
//   =sink      TypeName_sink(dest, src)          — move (transfer ownership)
//   =wasMoved  TypeName_wasMoved(self)           — zero RC handles after move
//   =dup       TypeName_dup(src): TypeName       — clone (init + copy, return)
//   =trace     TypeName_trace(self, callback)    — ORC cycle tracing (cyclic types only)
//   TypeInfo   TypeName_typeInfo                  — msTypeInfo for ORC runtime

import {
	Node, NodeKind, DeclKind, ProgramData, FunctionDeclData, SourceLocation,
	InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData,
} from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, createTransformContextWithChecker } from "../context";
import { makeIdent, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeNull, makeString, makeBool, makeObjectLiteral } from "../util";
import { Type, TypeKind, isPrimitiveKind } from "../../checker/types";
import { lookupSymbol, SymbolKind, isPointerType as isPointerTypeBase } from "../../checker/symbol";
import { checkProgram } from "../../checker/checkPass";
import { StmtBuf } from "../../analyzer/scope";
import { test, check, testGroup } from "std/testing";
import { parseInput } from "../testUtil";

// ===== DRC-safe collectors (Node[] is value type — gotcha #4) =====

interface DeclCollector {
	decls: Node[];
}

// ===== Lift Context (Nim's TLiftCtx) =====

interface LiftCtx {
	ctx: TransformContext;
	generated: NameSet;    // fully generated types (dedup)
	generating: NameSet;   // currently generating (cycle guard)
	collector: DeclCollector;
	cyclicCache: NameSet;     // types confirmed cyclic
	nonCyclicCache: NameSet;  // types confirmed non-cyclic
}

// ===== Pointer Type Wrapper (adapts SymbolTable-based helper to TransformContext) =====

function isPointerType(fieldType: Type, ctx: TransformContext): boolean {
	return isPointerTypeBase(fieldType, ctx.checkerCtx.table);
}

function namedTypeHasHooks(typeName: string, lctx: LiftCtx): boolean {
	return nameSetContains(lctx.generated, typeName) || nameSetContains(lctx.generating, typeName);
}

// ===== Cycle Detection (Nim's cyclicType) =====
// Determines if a type can form reference cycles (needed for =trace hook).

function isCyclicType(t: Type, lctx: LiftCtx, visited: NameSet): boolean {
	if (t === null) return false;
	if (isPrimitiveKind(t.kind) || t.kind === TypeKind.String) return false;

	match (t.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Function => { return true; },
		TypeKind.Array | TypeKind.Distinct => {
			if (t.typeReturn === null) return false;
			return isCyclicType(t.typeReturn, lctx, visited);
		},
		TypeKind.Object => {
			if (t.typeName !== "") {
				if (nameSetContains(lctx.cyclicCache, t.typeName)) return true;
				if (nameSetContains(lctx.nonCyclicCache, t.typeName)) return false;
				if (nameSetContains(visited, t.typeName)) return false;
				nameSetAdd(visited, t.typeName);
			}
			for (const child of t.typeChildren) {
				if (isCyclicType(child, lctx, visited)) {
					if (t.typeName !== "") nameSetAdd(lctx.cyclicCache, t.typeName);
					return true;
				}
			}
			if (t.typeName !== "") nameSetAdd(lctx.nonCyclicCache, t.typeName);
			return false;
		},
		TypeKind.Tuple => {
			for (const child of t.typeChildren) {
				if (isCyclicType(child, lctx, visited)) return true;
			}
			return false;
		},
		TypeKind.TypeReference => {
			if (t.typeName === "") return false;
			if (nameSetContains(visited, t.typeName)) return false;
			nameSetAdd(visited, t.typeName);
			const sym = lookupSymbol(lctx.ctx.checkerCtx.table, t.typeName);
			if (sym === null) return false;
			return isCyclicType(sym.symbolType, lctx, visited);
		},
		_ => { return false; },
	};
	return false;
}

// ===== Hook Suffix (shared by generateHook + base class dispatch) =====

function hookSuffix(hook: string): string {
	return match (hook) {
		"destroy" => "_destroy",
		"copy" => "_copy",
		"sink" => "_sink",
		"trace" => "_trace",
		_ => "_wasMoved",
	};
}

// ===== Nim's defaultOp =====
// Primitives: copy/sink => assign, destroy/wasMoved => no-op

function defaultOp(hook: string, x: Node, y: Node, buf: StmtBuf, loc: SourceLocation): void {
	if (hook === "copy" || hook === "sink") {
		buf.stmts.push(makeExprStmt(makeAssign(x, y, loc), loc));
	}
}

// ===== Emit helpers =====

// Emit runtime call — unary (destroy/wasMoved) or binary (copy/sink)
function genCall(name: string, hook: string, x: Node, y: Node, buf: StmtBuf, loc: SourceLocation): void {
	if (hook === "destroy" || hook === "wasMoved") {
		buf.stmts.push(makeExprStmt(makeCall(makeIdent(name, loc), [x], loc), loc));
	} else {
		buf.stmts.push(makeExprStmt(makeCall(makeIdent(name, loc), [x, y], loc), loc));
	}
}

// Copy-ref pattern: assign + incref on fresh dest node (avoids AST sharing)
function genCopyRef(increfFn: string, x: Node, y: Node, fieldName: string, buf: StmtBuf, loc: SourceLocation): void {
	buf.stmts.push(makeExprStmt(makeAssign(x, y, loc), loc));
	const fresh = fieldName !== ""
		? makeMember(makeIdent("dest", loc), fieldName, loc)
		: makeIdent("dest", loc);
	buf.stmts.push(makeExprStmt(makeCall(makeIdent(increfFn, loc), [fresh], loc), loc));
}

// Inline sink: destroy old value + raw assign (eliminates per-field function call)
function genInlineSink(destroyFn: string, xf: Node, yf: Node, buf: StmtBuf, loc: SourceLocation): void {
	genCall(destroyFn, "destroy", xf, yf, buf, loc);
	buf.stmts.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
}

// ===== Type Family Helpers (Nim's modular pattern) =====
// Each helper owns all runtime names for its type family.

// --- Nim's fillStrOp ---
function stringOp(hook: string, xf: Node, yf: Node, fieldName: string, buf: StmtBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("ms_string_decref", hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef("ms_string_incref", xf, yf, fieldName, buf, loc); },
		"sink" => { genInlineSink("ms_string_decref", xf, yf, buf, loc); },
		"wasMoved" => { genCall("ms_string_was_moved", hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Nim's fillSeqOp (3 element specializations) ---
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, buf: StmtBuf, loc: SourceLocation): void {
	if (elem === null || isPrimitiveKind(elem.kind)) {
		match (hook) {
			"destroy" => { genCall("ms_array_destroy", hook, xf, yf, buf, loc); },
			"copy" => { genCall("ms_array_copy", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("ms_array_destroy", xf, yf, buf, loc); },
			"wasMoved" => { genCall("ms_array_number_was_moved", hook, xf, yf, buf, loc); },
			_ => {},
		};
	} else if (elem.kind === TypeKind.String) {
		match (hook) {
			"destroy" => { genCall("ms_array_string_destroy", hook, xf, yf, buf, loc); },
			"copy" => { genCall("ms_array_string_copy", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("ms_array_string_destroy", xf, yf, buf, loc); },
			"wasMoved" => { genCall("ms_array_string_was_moved", hook, xf, yf, buf, loc); },
			_ => {},
		};
	} else {
		match (hook) {
			"destroy" => { genCall("MS_ARRAY_REF_DESTROY", hook, xf, yf, buf, loc); },
			"copy" => { genCall("MS_ARRAY_REF_COPY", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("MS_ARRAY_REF_DESTROY", xf, yf, buf, loc); },
			"wasMoved" => { genCall("MS_ARRAY_REF_WAS_MOVED", hook, xf, yf, buf, loc); },
			"trace" => { genCall("ms_array_ref_trace", hook, xf, yf, buf, loc); },
			_ => {},
		};
	}
}

// --- Nim's atomicRefOp (shared by Ref, Ptr, Object-pointer) ---
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, buf: StmtBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("ms_decref", hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef("ms_incref", xf, yf, fieldName, buf, loc); },
		"sink" => { buf.stmts.push(makeExprStmt(makeAssign(xf, yf, loc), loc)); },
		"wasMoved" => { genCall("ms_ptr_was_moved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Call callback(field) — yf is the trace callback
			buf.stmts.push(makeExprStmt(makeCall(yf, [xf], loc), loc));
		},
		_ => {},
	};
}

// --- Nim's fillBodyObjT for named value-type objects ---
function namedObjOp(hook: string, typeName: string, xf: Node, yf: Node, buf: StmtBuf, loc: SourceLocation): void {
	if (hook === "sink") {
		genInlineSink(typeName + "_destroy", xf, yf, buf, loc);
		return;
	}
	const name = hook === "wasMoved" ? "object_was_moved" : typeName + hookSuffix(hook);
	genCall(name, hook, xf, yf, buf, loc);
}

// --- Parameterized runtime op (shared by closure, map) ---
function runtimeOp(prefix: string, destroyName: string, hasTrace: boolean, hook: string, xf: Node, yf: Node, buf: StmtBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall(destroyName, hook, xf, yf, buf, loc); },
		"copy" => { genCall(prefix + "_copy", hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink(destroyName, xf, yf, buf, loc); },
		"wasMoved" => { genCall(prefix + "_was_moved", hook, xf, yf, buf, loc); },
		"trace" => { if (hasTrace) genCall(prefix + "_trace", hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Set lifecycle ---
function setOp(hook: string, xf: Node, yf: Node, buf: StmtBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("ms_set_free", hook, xf, yf, buf, loc); },
		"copy" => { genCall("ms_set_copy", hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink("ms_set_free", xf, yf, buf, loc); },
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// ===== fillBody — pure routing table (Nim pattern) =====
// Routes TypeKind to type family helper. No inline hook logic.

function fillBody(hook: string, x: Node, y: Node, fieldName: string, fieldType: Type, lctx: LiftCtx, buf: StmtBuf, visited: NameSet, loc: SourceLocation): void {
	const xf = fieldName !== ""
		? makeMember(x, fieldName, loc)
		: x;
	const yf = fieldName !== ""
		? makeMember(y, fieldName, loc)
		: y;

	// Primitives fall through to _ => defaultOp (isPrimitiveKind is canonical list)
	match (fieldType.kind) {
		TypeKind.String => { stringOp(hook, xf, yf, fieldName, buf, loc); },
		TypeKind.Array => { arrayOp(hook, fieldType.typeReturn, xf, yf, buf, loc); },
		TypeKind.Object => {
			if (isPointerType(fieldType, lctx.ctx)) {
				refOp(hook, xf, yf, fieldName, buf, loc);
			} else if (fieldType.typeName !== "") {
				ensureTypeHooks(fieldType.typeName, lctx, loc);
				if (namedTypeHasHooks(fieldType.typeName, lctx)) {
					namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
				} else {
					defaultOp(hook, xf, yf, buf, loc);
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Ref | TypeKind.Ptr => { refOp(hook, xf, yf, fieldName, buf, loc); },
		TypeKind.Function => { runtimeOp("ms_closure", "ms_closure_destroy", true, hook, xf, yf, buf, loc); },
		TypeKind.Map => { runtimeOp("ms_map", "ms_map_free", false, hook, xf, yf, buf, loc); },
		TypeKind.Set => { setOp(hook, xf, yf, buf, loc); },
		TypeKind.Tuple => {
			// Iterate tuple fields by name (Nim's fillBodyTup)
			let ti = 0;
			while (ti < fieldType.typeChildren.length) {
				const visited2: NameSet = { names: [] };
				if (ti < fieldType.typeNames.length) {
					fillBody(hook, xf, yf, fieldType.typeNames[ti], fieldType.typeChildren[ti], lctx, buf, visited2, loc);
				}
				ti += 1;
			}
		},
		TypeKind.Result | TypeKind.Union => {},
		TypeKind.Distinct => {
			if (fieldType.typeReturn !== null) {
				fillBody(hook, x, y, fieldName, fieldType.typeReturn, lctx, buf, visited, loc);
			}
		},
		TypeKind.TypeReference => {
			if (fieldType.typeName === "") return;
			if (nameSetContains(visited, fieldType.typeName)) return;
			nameSetAdd(visited, fieldType.typeName);
			const sym = lookupSymbol(lctx.ctx.checkerCtx.table, fieldType.typeName);
			if (sym === null) return;
			fillBody(hook, x, y, fieldName, sym.symbolType, lctx, buf, visited, loc);
		},
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// ===== Needs Hooks Check =====
// Probe: run fillBody("destroy") on throwaway buf. If it emits anything, type needs hooks.

function typeNeedsHooks(objType: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	if (objType.kind !== TypeKind.Object) return false;
	const probe: StmtBuf = { stmts: [] };
	let i = 0;
	while (i < objType.typeNames.length) {
		const visited: NameSet = { names: [] };
		fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), objType.typeNames[i], objType.typeChildren[i], lctx, probe, visited, loc);
		if (probe.stmts.length > 0) return true;
		i += 1;
	}
	return false;
}

// ===== Inheritance Helper (Nim's fillBodyObjTImpl) =====

function getBaseClass(typeName: string, lctx: LiftCtx): string {
	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return "";
	if (sym.symbolKind !== SymbolKind.Class) return "";
	if (sym.symbolType.typeExtra === null) return "";
	if (sym.symbolType.typeExtra.kind !== TypeKind.TypeReference) return "";
	return sym.symbolType.typeExtra.typeName;
}

// ===== User-Defined Hook Dispatch (Nim's considerUserDefinedOp) =====
// Maps lifecycle hooks to user extension method names.

function userHookName(typeName: string, hook: string): string {
	const suffix = match (hook) {
		"destroy" => "_onDestroy",
		"copy" => "_onCopy",
		"sink" => "_onMove",
		"wasMoved" => "_onMoved",
		"dup" => "_onClone",
		"trace" => "_onTrace",
		_ => "",
	};
	if (suffix === "") return "";
	return typeName + suffix;
}

function hasUserDefinedHook(typeName: string, hook: string, lctx: LiftCtx): boolean {
	const name = userHookName(typeName, hook);
	if (name === "") return false;
	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, name);
	return sym !== null;
}

// ===== Generate a single hook (Nim's produceSym per op) =====

function generateHook(hook: string, typeName: string, objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: StmtBuf = { stmts: [] };
	const isTrace = hook === "trace";
	const isUnary = hook === "destroy" || hook === "wasMoved" || isTrace;
	const p1 = isUnary ? "self" : "dest";
	const p2 = match (hook) {
		"trace" => "callback",
		"destroy" | "wasMoved" => "self",
		_ => "src",
	};

	// Self-assignment check for copy/sink (Nim's checkSelfAssignment)
	if (hook === "copy" || hook === "sink") {
		const selfCheck = makeIf(
			makeBinary(makeIdent(p1, loc), "===", makeIdent(p2, loc), loc),
			makeBlock([makeReturn(makeNull(loc), loc)], loc),
			makeNull(loc),
			loc,
		);
		buf.stmts.push(selfCheck);
	}

	// User-defined hook dispatch (Nim's considerUserDefinedOp)
	if (hasUserDefinedHook(typeName, hook, lctx)) {
		const uName = userHookName(typeName, hook);
		if (isUnary) {
			buf.stmts.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc)], loc), loc));
		} else {
			buf.stmts.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc), makeIdent(p2, loc)], loc), loc));
		}
	} else {
		// Inheritance: ensure base class hooks exist (Nim's fillBodyObjTImpl)
		const baseTypeName = getBaseClass(typeName, lctx);
		if (baseTypeName !== "") {
			ensureTypeHooks(baseTypeName, lctx, loc);
		}

		if (hook === "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — Nim pattern)
			let i = objType.typeNames.length;
			while (i > 0) {
				i -= 1;
				const visited: NameSet = { names: [] };
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + "_destroy", hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (Nim pattern)
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + hookSuffix(hook), hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
			let i = 0;
			while (i < objType.typeNames.length) {
				const visited: NameSet = { names: [] };
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
				i += 1;
			}
		}
	}

	const suffix = hookSuffix(hook);

	if (isTrace) {
		// trace(self, callback) — callback is a function pointer (void*)
		lctx.collector.decls.push(makeFnDecl(typeName + suffix, [p1, p2], [typeName, "void*"], makeBlock(buf.stmts, loc), "", "void", loc));
	} else if (isUnary) {
		lctx.collector.decls.push(makeFnDecl(typeName + suffix, [p1], [typeName], makeBlock(buf.stmts, loc), "", "void", loc));
	} else {
		lctx.collector.decls.push(makeFnDecl(typeName + suffix, [p1, p2], [typeName, typeName], makeBlock(buf.stmts, loc), "", "void", loc));
	}
}

// ===== Ensure Type Hooks (Nim's produceSym + fillBody) =====

function ensureTypeHooks(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName)) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	if (sym.symbolType.kind !== TypeKind.Object) return;

	const objType = sym.symbolType;
	if (!typeNeedsHooks(objType, lctx, loc)) return;

	// 4 core hooks via fillBody dispatch
	generateHook("destroy", typeName, objType, lctx, loc);
	generateHook("copy", typeName, objType, lctx, loc);
	generateHook("sink", typeName, objType, lctx, loc);
	generateHook("wasMoved", typeName, objType, lctx, loc);

	// =trace: ORC cycle detection (only for cyclic types)
	const visited: NameSet = { names: [] };
	const hasCycles = isCyclicType(objType, lctx, visited);
	if (hasCycles) {
		generateHook("trace", typeName, objType, lctx, loc);
	}

	// =dup: init + copy, return (Nim pattern)
	const dupStmts: Node[] = [];
	dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
	dupStmts.push(makeExprStmt(makeCall(makeIdent(typeName + "_copy", loc), [makeIdent("$result", loc), makeIdent("src", loc)], loc), loc));
	dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	lctx.collector.decls.push(makeFnDecl(typeName + "_dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc));

	// msTypeInfo generation for ORC runtime
	const traceFn = hasCycles ? makeIdent(typeName + "_trace", loc) : makeNull(loc);
	const typeInfoObj = makeObjectLiteral(
		["name", "is_cyclic", "trace_fn", "destroy_fn"],
		[makeString(typeName, loc), makeBool(hasCycles, loc), traceFn, makeIdent(typeName + "_destroy", loc)],
		loc,
	);
	lctx.collector.decls.push(makeVarDecl(typeName + "_typeInfo", typeInfoObj, DeclKind.Const, loc));

	nameSetAdd(lctx.generated, typeName);
}

// ===== Process Declarations =====

function processDecl(stmt: Node, lctx: LiftCtx): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl => {
			const d = stmt.data as InterfaceDeclData;
			ensureTypeHooks(d.interfaceName, lctx, stmt.location);
		},
		NodeKind.ClassDecl => {
			const d = stmt.data as ClassDeclData;
			ensureTypeHooks(d.className, lctx, stmt.location);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			processDecl(ed.exportedDecl, lctx);
		},
		_ => {},
	};
}

// ===== Main Entry Point =====

export function liftDestructors(program: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx === null) return program;

	const pd = program.data as ProgramData;
	const lctx: LiftCtx = {
		ctx,
		generated: { names: [] },
		generating: { names: [] },
		collector: { decls: [] },
		cyclicCache: { names: [] },
		nonCyclicCache: { names: [] },
	};

	for (const stmt of pd.programStmts) {
		processDecl(stmt, lctx);
	}

	for (const decl of lctx.collector.decls) {
		pd.programStmts.push(decl);
	}

	return program;
}

// ===== Tests =====

function liftWithChecker(input: string): Node {
	const pr = parseInput(input);
	if (!pr.ok) return pr.value;
	const checkerCtx = checkProgram(pr.value);
	const ctx = createTransformContextWithChecker(checkerCtx);
	return liftDestructors(pr.value, ctx);
}


// Count generated lifecycle hook functions (5 base + optional trace)
function generatedFnCount(input: string): number {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	let count = 0;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (d.fnName.endsWith("_destroy")
				|| d.fnName.endsWith("_copy")
				|| d.fnName.endsWith("_sink")
				|| d.fnName.endsWith("_wasMoved")
				|| d.fnName.endsWith("_dup")
				|| d.fnName.endsWith("_trace")) {
				count += 1;
			}
		}
	}
	return count;
}

// Check if a specific named function was generated
function hasGeneratedFn(input: string, fnSuffix: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (d.fnName.endsWith( fnSuffix)) return true;
		}
	}
	return false;
}

// Check if a TypeInfo variable was generated
function hasTypeInfo(input: string, typeName: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.VariableDecl) {
			const d = stmt.data as VariableDeclData;
			if (d.declName === typeName + "_typeInfo") return true;
		}
	}
	return false;
}

testGroup("Destructor Lifting - Generic", () => {
	test("primitive-only no hooks", () => {
		check(generatedFnCount("interface Point { x: number; y: number; }") === 0);
	});
	test("string field generates 5 hooks", () => {
		check(generatedFnCount("interface Token { value: string; }") === 5);
	});
	test("array field generates 5 hooks", () => {
		check(generatedFnCount("interface Data { items: number[]; }") === 5);
	});
	test("nested interface generates 10 hooks", () => {
		check(generatedFnCount("interface A { name: string; } interface B { a: A; }") === 10);
	});
	test("no duplicates", () => {
		check(generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") === 10);
	});
	test("exported interface", () => {
		check(generatedFnCount("export interface Token { value: string; }") === 5);
	});
	test("no interfaces passthrough", () => {
		check(generatedFnCount("const x = 1;") === 0);
	});
});

testGroup("Destructor Lifting - Lifecycle", () => {
	// =trace: Function fields are cyclic (closures capture refs)
	test("trace NOT generated for flat string", () => {
		check(!hasGeneratedFn("interface Token { value: string; }", "Token_trace"));
	});

	// TypeInfo generated alongside hooks
	test("typeInfo generated", () => {
		check(hasTypeInfo("interface Token { value: string; }", "Token"));
	});
	test("typeInfo NOT generated for primitives", () => {
		check(!hasTypeInfo("interface Point { x: number; y: number; }", "Point"));
	});

	// Inheritance: child with own hookable field + base both generate hooks
	test("inheritance generates parent hooks", () => {
		const src = "interface Base { name: string; } class Child extends Base { extra: string; }";
		check(hasGeneratedFn(src, "Base_destroy"));
	});

	// All 5 core hooks present for a hookable type
	test("all core hooks generated", () => {
		const src = "interface Wrap { data: string; }";
		check(hasGeneratedFn(src, "_destroy"));
		check(hasGeneratedFn(src, "_copy"));
		check(hasGeneratedFn(src, "_sink"));
		check(hasGeneratedFn(src, "_wasMoved"));
		check(hasGeneratedFn(src, "_dup"));
	});
});
