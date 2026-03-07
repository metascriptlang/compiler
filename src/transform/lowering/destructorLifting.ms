// Destructor Lifting — generate per-type lifecycle hook function bodies
//
// Standard reference implementation for lifecycle hook generation
// Routing table: TypeKind → type family helper
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
import { makeIdent, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeUnary, makeNull, makeString, makeBool, makeObjectLiteral } from "../util";
import { Type, TypeKind, isPrimitiveKind, AttachedOp, setAttachedOp, tupleTypeName } from "../../checker/types";
import { lookupSymbol, SymbolKind, isPointerType as isPointerTypeBase } from "../../checker/symbol";
import { checkProgram } from "../../checker/checkPass";
import { parseInput } from "../testUtil";

// ===== Lift Context (reference TLiftCtx) =====

interface LiftCtx {
	ctx: TransformContext;
	generated: NameSet;    // fully generated types (dedup)
	generating: NameSet;   // currently generating (cycle guard)
	collector: Node[];
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

// ===== Cycle Detection (reference cyclicType) =====
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

// ===== Reference defaultOp =====
// Primitives: copy/sink => assign, destroy/wasMoved => no-op

function defaultOp(hook: string, x: Node, y: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "copy" || hook === "sink") {
		buf.push(makeExprStmt(makeAssign(x, y, loc), loc));
	}
}

// ===== Emit helpers =====

// Emit runtime call — unary (destroy/wasMoved) or binary (copy/sink)
function genCall(name: string, hook: string, x: Node, y: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "destroy" || hook === "wasMoved") {
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [x], loc), loc));
	} else {
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [x, y], loc), loc));
	}
}

// Copy-ref pattern: assign + incref on fresh dest node (avoids AST sharing)
function genCopyRef(increfFn: string, x: Node, y: Node, fieldName: string, buf: Node[], loc: SourceLocation): void {
	buf.push(makeExprStmt(makeAssign(x, y, loc), loc));
	const fresh = fieldName !== ""
		? makeMember(makeIdent("dest", loc), fieldName, loc)
		: makeIdent("dest", loc);
	buf.push(makeExprStmt(makeCall(makeIdent(increfFn, loc), [fresh], loc), loc));
}

// Inline sink: destroy old value + raw assign (eliminates per-field function call)
function genInlineSink(destroyFn: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	genCall(destroyFn, "destroy", xf, yf, buf, loc);
	buf.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
}

// ===== Type Family Helpers (Modular pattern) =====
// Each helper owns all runtime names for its type family.

// --- Standard string hook generator ---
function stringOp(hook: string, xf: Node, yf: Node, fieldName: string, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("msStringDecref", hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef("msStringIncref", xf, yf, fieldName, buf, loc); },
		"sink" => { genInlineSink("msStringDecref", xf, yf, buf, loc); },
		"wasMoved" => { genCall("msStringWasMoved", hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Standard sequence/array hook generator ---
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	if (elem === null || isPrimitiveKind(elem.kind)) {
		match (hook) {
			"destroy" => { genCall("msArrayDestroy", hook, xf, yf, buf, loc); },
			"copy" => { genCall("msArrayCopy", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("msArrayDestroy", xf, yf, buf, loc); },
			"wasMoved" => { genCall("msArrayNumberWasMoved", hook, xf, yf, buf, loc); },
			_ => {},
		};
	} else if (elem.kind === TypeKind.String) {
		match (hook) {
			"destroy" => { genCall("msArrayStringDestroy", hook, xf, yf, buf, loc); },
			"copy" => { genCall("msArrayStringCopy", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("msArrayStringDestroy", xf, yf, buf, loc); },
			"wasMoved" => { genCall("msArrayStringWasMoved", hook, xf, yf, buf, loc); },
			_ => {},
		};
	} else {
		match (hook) {
			"destroy" => { genCall("msArrayRefDestroy", hook, xf, yf, buf, loc); },
			"copy" => { genCall("msArrayRefCopy", hook, xf, yf, buf, loc); },
			"sink" => { genInlineSink("msArrayRefDestroy", xf, yf, buf, loc); },
			"wasMoved" => { genCall("msArrayRefWasMoved", hook, xf, yf, buf, loc); },
			"trace" => { genCall("msArrayRefTrace", hook, xf, yf, buf, loc); },
			_ => {},
		};
	}
}

// --- Standard atomic reference hook generator ---
// isCyclic: true for types that can form reference cycles (reference parity: atomicRefOp)
// Cyclic types use msDecrefCyclic/msIncrefCyclic (ORC-aware when MS_ORC defined)
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, isCyclic: boolean, buf: Node[], loc: SourceLocation): void {
	const decrefFn = isCyclic ? "msDecrefCyclic" : "msDecref";
	const increfFn = isCyclic ? "msIncrefCyclic" : "msIncref";
	match (hook) {
		"destroy" => { genCall(decrefFn, hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef(increfFn, xf, yf, fieldName, buf, loc); },
		"sink" => { buf.push(makeExprStmt(makeAssign(xf, yf, loc), loc)); },
		"wasMoved" => { genCall("msPtrWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Call callback(field) — yf is the trace callback
			buf.push(makeExprStmt(makeCall(yf, [xf], loc), loc));
		},
		_ => {},
	};
}

// --- Standard value-type object hook generator ---
function namedObjOp(hook: string, typeName: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "sink") {
		genInlineSink(typeName + "_destroy", xf, yf, buf, loc);
		return;
	}
	const name = hook === "wasMoved" ? "msObjectWasMoved" : typeName + hookSuffix(hook);
	genCall(name, hook, xf, yf, buf, loc);
}

// --- Parameterized runtime op (shared by closure, map) ---
function runtimeOp(prefix: string, destroyName: string, copySuffix: string, wasMovedSuffix: string, traceSuffix: string, hasTrace: boolean, hook: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall(destroyName, hook, xf, yf, buf, loc); },
		"copy" => { genCall(prefix + copySuffix, hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink(destroyName, xf, yf, buf, loc); },
		"wasMoved" => { genCall(prefix + wasMovedSuffix, hook, xf, yf, buf, loc); },
		"trace" => { if (hasTrace) genCall(prefix + traceSuffix, hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Set lifecycle ---
function setOp(hook: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("msSetFree", hook, xf, yf, buf, loc); },
		"copy" => { genCall("msSetCopy", hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink("msSetFree", xf, yf, buf, loc); },
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// ===== fillBody — pure routing table (Standard pattern) =====
// Routes TypeKind to type family helper. No inline hook logic.

function fillBody(hook: string, x: Node, y: Node, fieldName: string, fieldType: Type, lctx: LiftCtx, buf: Node[], visited: NameSet, loc: SourceLocation): void {
	const xf = fieldName !== ""
		? makeMember(x, fieldName, loc)
		: x;
	const yf = fieldName !== ""
		? makeMember(y, fieldName, loc)
		: y;

	// Tuple case extracted from match (MetaScript match arm limitation with block-scoped vars)
	if (fieldType.kind === TypeKind.Tuple) {
		let ti = 0;
		while (ti < fieldType.typeChildren.length) {
			const visited2: NameSet = [];
			// Use named field if available, otherwise positional _0, _1 pattern
			const tupleFn = (ti < fieldType.typeNames.length && fieldType.typeNames[ti].length > 0)
				? fieldType.typeNames[ti]
				: "_" + ti.toString();
			fillBody(hook, xf, yf, tupleFn, fieldType.typeChildren[ti], lctx, buf, visited2, loc);
			ti += 1;
		}
		return;
	}

	// Primitives fall through to _ => defaultOp (isPrimitiveKind is canonical list)
	match (fieldType.kind) {
		TypeKind.String => { stringOp(hook, xf, yf, fieldName, buf, loc); },
		TypeKind.Array => { arrayOp(hook, fieldType.typeReturn, xf, yf, buf, loc); },
		TypeKind.Object => {
			if (isPointerType(fieldType, lctx.ctx)) {
				const cyclic = isCyclicType(fieldType, lctx, visited);
				refOp(hook, xf, yf, fieldName, cyclic, buf, loc);
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
		TypeKind.Ref | TypeKind.Ptr => {
			const cyclic = isCyclicType(fieldType, lctx, visited);
			refOp(hook, xf, yf, fieldName, cyclic, buf, loc);
		},
		TypeKind.Function => { runtimeOp("msClosure", "msClosureDestroy", "Copy", "WasMoved", "Trace", true, hook, xf, yf, buf, loc); },
		TypeKind.Map => { runtimeOp("msMap", "msMapFree", "Copy", "WasMoved", "Trace", false, hook, xf, yf, buf, loc); },
		TypeKind.Set => { setOp(hook, xf, yf, buf, loc); },
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
	const probe: Node[] = [];
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const visited: NameSet = [];
		fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), objType.typeNames[i], objType.typeChildren[i], lctx, probe, visited, loc);
		if (probe.length > 0) return true;
	}
	return false;
}

// ===== Inheritance Helper (Standard reference pattern) =====

function getBaseClass(typeName: string, lctx: LiftCtx): string {
	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return "";
	if (sym.symbolKind !== SymbolKind.Class) return "";
	if (sym.symbolType.typeExtra === null) return "";
	if (sym.symbolType.typeExtra.kind !== TypeKind.TypeReference) return "";
	return sym.symbolType.typeExtra.typeName;
}

// ===== User-Defined Hook Dispatch (Reference considerUserDefinedOp) =====
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

// ===== Generate a single hook (Reference produceSym per op) =====

function generateHook(hook: string, typeName: string, objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	const isTrace = hook === "trace";
	const isUnary = hook === "destroy" || hook === "wasMoved" || isTrace;
	const p1 = isUnary ? "self" : "dest";
	const p2 = match (hook) {
		"trace" => "callback",
		"destroy" | "wasMoved" => "self",
		_ => "src",
	};

	// Self-assignment check for copy/sink (Implementation parity)
	// Set nodeType on operands so codegen can emit memcmp for struct equality (E1 fix)
	if (hook === "copy" || hook === "sink") {
		const destIdent = makeIdent(p1, loc);
		destIdent.nodeType = objType;
		const srcIdent = makeIdent(p2, loc);
		srcIdent.nodeType = objType;
		const selfCheck = makeIf(
			makeBinary(destIdent, "===", srcIdent, loc),
			makeBlock([makeReturn(makeNull(loc), loc)], loc),
			makeNull(loc),
			loc,
		);
		buf.push(selfCheck);
	}

	// User-defined hook dispatch (Reference considerUserDefinedOp)
	if (hasUserDefinedHook(typeName, hook, lctx)) {
		const uName = userHookName(typeName, hook);
		if (isUnary) {
			buf.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc)], loc), loc));
		} else {
			buf.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc), makeIdent(p2, loc)], loc), loc));
		}
	} else {
		// Inheritance: ensure base class hooks exist (Implementation parity)
		const baseTypeName = getBaseClass(typeName, lctx);
		if (baseTypeName !== "") {
			ensureTypeHooks(baseTypeName, lctx, loc);
		}

		if (hook === "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — standard pattern)
			for (let i = objType.typeNames.length - 1; i >= 0; i -= 1) {
				const visited: NameSet = [];
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + "_destroy", hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (standard pattern)
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + hookSuffix(hook), hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
			for (let i = 0; i < objType.typeNames.length; i += 1) {
				const visited: NameSet = [];
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
		}
	}

	const suffix = hookSuffix(hook);

	if (isTrace) {
		// trace(self, callback) — callback is a function pointer (void*)
		lctx.collector.push(makeFnDecl(typeName + suffix, [p1, p2], [typeName, "void*"], makeBlock(buf, loc), "", "void", loc));
	} else if (isUnary) {
		lctx.collector.push(makeFnDecl(typeName + suffix, [p1], [typeName], makeBlock(buf, loc), "", "void", loc));
	} else {
		lctx.collector.push(makeFnDecl(typeName + suffix, [p1, p2], [typeName, typeName], makeBlock(buf, loc), "", "void", loc));
	}
}

// ===== Ensure Type Hooks (Reference produceSym + fillBody) =====

function ensureTypeHooks(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName)) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	if (sym.symbolType.kind !== TypeKind.Object) return;

	const objType = sym.symbolType;
	if (!typeNeedsHooks(objType, lctx, loc)) {
		// Classes still need a minimal _typeInfo for msAllocTyped (even without RC hooks)
		if (sym.symbolKind === SymbolKind.Class) {
			const typeInfoObj = makeObjectLiteral(
				["name", "isCyclic", "traceFn", "destroyFn"],
				[makeString(typeName, loc), makeBool(false, loc), makeNull(loc), makeNull(loc)],
				loc,
			);
			lctx.collector.push(makeVarDecl(typeName + "_typeInfo", typeInfoObj, DeclKind.Const, loc));
			nameSetAdd(lctx.generated, typeName);
		}
		return;
	}

	// 4 core hooks via fillBody dispatch
	generateHook("destroy", typeName, objType, lctx, loc);
	generateHook("copy", typeName, objType, lctx, loc);
	generateHook("sink", typeName, objType, lctx, loc);
	generateHook("wasMoved", typeName, objType, lctx, loc);

	// Register hooks on the type (Standard reference parity)
	setAttachedOp(objType, AttachedOp.AttachedDestructor, typeName + "_destroy");
	setAttachedOp(objType, AttachedOp.AttachedAsgn, typeName + "_copy");
	setAttachedOp(objType, AttachedOp.AttachedSink, typeName + "_sink");
	setAttachedOp(objType, AttachedOp.AttachedWasMoved, typeName + "_wasMoved");

	// =trace: ORC cycle detection (only for cyclic types)
	const visited: NameSet = [];
	const hasCycles = isCyclicType(objType, lctx, visited);
	if (hasCycles) {
		generateHook("trace", typeName, objType, lctx, loc);
		setAttachedOp(objType, AttachedOp.AttachedTrace, typeName + "_trace");
	}

	// =dup: init + copy, return (standard pattern)
	const dupStmts: Node[] = [];
	dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
	dupStmts.push(makeExprStmt(makeCall(makeIdent(typeName + "_copy", loc), [makeIdent("$result", loc), makeIdent("src", loc)], loc), loc));
	dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	lctx.collector.push(makeFnDecl(typeName + "_dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc));
	setAttachedOp(objType, AttachedOp.AttachedDup, typeName + "_dup");

	// msTypeInfo generation for ORC runtime
	const traceFn = hasCycles ? makeIdent(typeName + "_trace", loc) : makeNull(loc);
	const typeInfoObj = makeObjectLiteral(
		["name", "isCyclic", "traceFn", "destroyFn"],
		[makeString(typeName, loc), makeBool(hasCycles, loc), traceFn, makeIdent(typeName + "_destroy", loc)],
		loc,
	);
	lctx.collector.push(makeVarDecl(typeName + "_typeInfo", typeInfoObj, DeclKind.Const, loc));

	nameSetAdd(lctx.generated, typeName);
}

// ===== Auto-Generated == (Nim parity: generic proc `==`*[T: tuple|object]) =====
// Generates TypeName_eq(a, b): boolean with field-by-field comparison.
// Nim uses compile-time `fields()` magic iterator unrolling; we do the same here
// by iterating typeNames/typeChildren at transform time.

function fieldEqExpr(aField: Node, bField: Node, fieldType: Type, lctx: LiftCtx, loc: SourceLocation): Node {
	// For nested value-type objects, call their _eq function
	if (fieldType.kind === TypeKind.Object && fieldType.typeName !== "" && (fieldType.typeFlags & 1) !== 0) {
		if (!isPointerType(fieldType, lctx.ctx)) {
			return makeCall(makeIdent(fieldType.typeName + "_eq", loc), [aField, bField], loc);
		}
	}
	// For TypeReference, resolve and recurse
	if (fieldType.kind === TypeKind.TypeReference && fieldType.typeName !== "") {
		const sym = lookupSymbol(lctx.ctx.checkerCtx.table, fieldType.typeName);
		if (sym !== null) {
			return fieldEqExpr(aField, bField, sym.symbolType, lctx, loc);
		}
	}
	// For all other types (primitives, strings, enums, etc): use === directly
	return makeBinary(aField, "===", bField, loc);
}

function generateEq(typeName: string, objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	// Build: function TypeName_eq(a: TypeName, b: TypeName): boolean {
	//   if (a.field1 !== b.field1) return false;
	//   if (a.field2 !== b.field2) return false;
	//   ...
	//   return true;
	// }
	const buf: Node[] = [];
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const fieldName = objType.typeNames[i];
		const fieldType = objType.typeChildren[i];
		const aField = makeMember(makeIdent("a", loc), fieldName, loc);
		const bField = makeMember(makeIdent("b", loc), fieldName, loc);

		// Generate: if (!fieldEq) return false;
		const eqExpr = fieldEqExpr(aField, bField, fieldType, lctx, loc);
		const notEq = makeUnary("!", eqExpr, loc);
		buf.push(makeIf(notEq, makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
	}
	buf.push(makeReturn(makeBool(true, loc), loc));
	lctx.collector.push(makeFnDecl(typeName + "_eq", ["a", "b"], [typeName, typeName], makeBlock(buf, loc), "", "boolean", loc));
	setAttachedOp(objType, AttachedOp.AttachedEq, typeName + "_eq");
}

// ===== Ensure Eq (called for ALL interface types, even primitive-only) =====

function ensureEq(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName + "_eq")) return;
	nameSetAdd(lctx.generated, typeName + "_eq");

	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	if (sym.symbolType.kind !== TypeKind.Object) return;
	// Only for value-type objects (interfaces), not ref-type classes
	if ((sym.symbolType.typeFlags & 1) === 0) return;

	generateEq(typeName, sym.symbolType, lctx, loc);
}

// ===== Tuple Comparison Operators (Nim parity: system.nim lines 1973-1996) =====
// Auto-generate ==, <, <= for tuples using positional field names (_0, _1, ...).
// Nim uses `fields()` magic iterator; we unroll at transform time.

// Tuple field access helper: a._0, a._1, etc.
function tupleField(obj: Node, idx: number, loc: SourceLocation): Node {
	return makeMember(obj, "_" + idx.toString(), loc);
}

// Generate element-by-element equality for tuples.
// Nim: proc `==`*[T: tuple|object](x, y: T): bool =
//        for a, b in fields(x, y): if a != b: return false
//        return true
function generateTupleEq(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		const eqExpr = fieldEqExpr(aField, bField, t.typeChildren[i], lctx, loc);
		buf.push(makeIf(makeUnary("!", eqExpr, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(true, loc), loc));
	lctx.collector.push(makeFnDecl(tupleName + "_eq", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
	setAttachedOp(t, AttachedOp.AttachedEq, tupleName + "_eq");
}

// Generate lexicographic < for tuples.
// Nim: proc `<`*[T: tuple](x, y: T): bool =
//        for a, b in fields(x, y):
//          var c = cmp(a, b)
//          if c < 0: return true
//          if c > 0: return false
//        return false
//
// We inline the cmp pattern: if (a < b) return true; if (a > b) return false;
function generateTupleLt(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		// if (a._i < b._i) return true;
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), makeNull(loc), loc));
		// if (a._i > b._i) return false;
		const aField2 = tupleField(makeIdent("a", loc), i, loc);
		const bField2 = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(false, loc), loc));
	lctx.collector.push(makeFnDecl(tupleName + "_lt", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
	setAttachedOp(t, AttachedOp.AttachedLt, tupleName + "_lt");
}

// Generate lexicographic <= for tuples.
// Nim: proc `<=`*[T: tuple](x, y: T): bool =
//        for a, b in fields(x, y):
//          var c = cmp(a, b)
//          if c < 0: return true
//          if c > 0: return false
//        return true    <-- only difference from <
function generateTupleLe(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), makeNull(loc), loc));
		const aField2 = tupleField(makeIdent("a", loc), i, loc);
		const bField2 = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(true, loc), loc));  // <= returns true when equal
	lctx.collector.push(makeFnDecl(tupleName + "_le", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
	setAttachedOp(t, AttachedOp.AttachedLe, tupleName + "_le");
}

// ===== Process Declarations =====

function processDecl(stmt: Node, lctx: LiftCtx): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl => {
			const d = stmt.data as InterfaceDeclData;
			ensureTypeHooks(d.interfaceName, lctx, stmt.location);
			ensureEq(d.interfaceName, lctx, stmt.location);
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
		generated: [],
		generating: [],
		collector: [],
		cyclicCache: [],
		nonCyclicCache: [],
	};

	for (const stmt of pd.programStmts) {
		processDecl(stmt, lctx);
	}

	// Process pending tuple comparison ops (collected by operatorLower).
	// Nim parity: system.nim:1973 (==), :1980 (<=), :1989 (<) for tuples.
	const defaultLoc: SourceLocation = { file: "", line: 0, column: 0 };
	for (const pending of ctx.pendingTupleOps) {
		for (const op of pending.ops) {
			const key = pending.tupleName + op;
			if (nameSetContains(lctx.generated, key)) continue;
			nameSetAdd(lctx.generated, key);
			if (op === "_eq") {
				generateTupleEq(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			} else if (op === "_lt") {
				generateTupleLt(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			} else if (op === "_le") {
				generateTupleLe(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			}
		}
	}

	for (const decl of lctx.collector) {
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

test "primitive-only no hooks" { assert generatedFnCount("interface Point { x: number; y: number; }") === 0; }

test "string field generates 5 hooks" { assert generatedFnCount("interface Token { value: string; }") === 5; }

test "array field generates 5 hooks" { assert generatedFnCount("interface Data { items: number[]; }") === 5; }

test "nested interface generates 10 hooks" { assert generatedFnCount("interface A { name: string; } interface B { a: A; }") === 10; }

test "no duplicates" { assert generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") === 10; }

test "exported interface" { assert generatedFnCount("export interface Token { value: string; }") === 5; }

test "no interfaces passthrough" { assert generatedFnCount("const x = 1;") === 0; }
// =trace: Function fields are cyclic (closures capture refs)
test "trace NOT generated for flat string" { assert !hasGeneratedFn("interface Token { value: string; }", "Token_trace"); }
// TypeInfo generated alongside hooks
test "typeInfo generated" { assert hasTypeInfo("interface Token { value: string; }", "Token"); }

test "typeInfo NOT generated for primitives" { assert !hasTypeInfo("interface Point { x: number; y: number; }", "Point"); }
// Inheritance: child with own hookable field + base both generate hooks
test "inheritance generates parent hooks" {
	const src = "interface Base { name: string; } class Child extends Base { extra: string; }";
	assert hasGeneratedFn(src, "Base_destroy");
}
// All 5 core hooks present for a hookable type
test "all core hooks generated" {
	const src = "interface Wrap { data: string; }";
	assert hasGeneratedFn(src, "_destroy");
	assert hasGeneratedFn(src, "_copy");
	assert hasGeneratedFn(src, "_sink");
	assert hasGeneratedFn(src, "_wasMoved");
	assert hasGeneratedFn(src, "_dup");
}

// Auto-generated == (Nim parity: generic proc `==`*[T: tuple|object])
test "eq generated for primitive-only interface" {
	assert hasGeneratedFn("interface Point { x: number; y: number; }", "Point_eq");
}

test "eq generated for string-field interface" {
	assert hasGeneratedFn("interface Token { value: string; }", "Token_eq");
}

test "eq generated for exported interface" {
	assert hasGeneratedFn("export interface Loc { line: number; col: number; }", "Loc_eq");
}

test "eq NOT generated for class" {
	assert !hasGeneratedFn("class Obj { x: number; }", "Obj_eq");
}
