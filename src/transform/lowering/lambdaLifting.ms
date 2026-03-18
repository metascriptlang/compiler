// Lambda Lifting — converts closures with captures into lifted functions + env structs
// Single-pass implementation: detect captures + rewrite in one top-down recursive walk
//
// function outer() {
//   let x = 10;
//   const f = () => x + 1;        // captures x
// }
//
// Becomes:
//   interface $Env_outer_1 { x: unknown; }
//   function $lifted_outer_1(_envP, ...) { return _envP.x + 1; }
//   function outer() {
//     let x = 10;
//     const f = { fn: $lifted_outer_1, env: { x: x } };
//   }

import { Node, NodeKind, SourceLocation, NodeFlag, SymbolKind, createNode, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ExprStmtData, ReturnStmtData, BinaryExprData, CallExprData, UnaryExprData, IdentifierData, Type, TypeKind } from "../../ast/node";
import { TransformContext, NameSet, createNameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeIdent, makeMember, makeMoveExpr, makeReturn, makeBlock,
	makeFnDecl, makeInterfaceDeclFromTypes, makeObjectLiteral, makeHiddenDeref,
	makeNull, syntheticToken,
} from "../util";
import { createPtr, unknownType } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts } from "../testUtil";

// ===== Scope Stack =====
// Tracks variable declarations with function boundary awareness.

interface ScopeStack {
	names: string[];
	funcMarkers: number[];
}

function createScopeStack(): ScopeStack {
	const ss: ScopeStack = { names: [], funcMarkers: [] };
	return ss;
}

function pushFuncBoundary(ss: ScopeStack): void {
	ss.funcMarkers.push(ss.names.length);
}

function popFuncBoundary(ss: ScopeStack): void {
	const marker = ss.funcMarkers[ss.funcMarkers.length - 1];
	while (ss.names.length > marker) {
		ss.names.pop();
	}
	ss.funcMarkers.pop();
}

function defineVar(ss: ScopeStack, name: string): void {
	ss.names.push(name);
}

function isLocalVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length === 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = funcStart; i < ss.names.length; i += 1) {
		if (ss.names[i] === name) return true;
	}
	return false;
}

function isOuterVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length === 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = 0; i < funcStart; i += 1) {
		if (ss.names[i] === name) return true;
	}
	return false;
}

// ===== Built-in Names =====

function isBuiltinName(name: string): boolean {
	return match (name) {
		"console" | "Result" | "true" | "false" | "null" | "undefined" |
		"NaN" | "Infinity" | "Math" | "JSON" | "parseInt" | "parseFloat" |
		"String" | "Number" | "Boolean" | "Array" | "Object" | "Error" |
		"Promise" | "Map" | "Set" | "require" | "module" | "exports" |
		"globalThis" | "check" | "test" | "testGroup" => true,
		_ => false,
	};
}

// ===== Lift State =====
// Accumulated during the walk — env structs and lifted functions prepended to program.

interface VarTypeEntry {
	name: string;
	typeStr: string;
}

interface LiftState {
	liftedFunctions: Node[];
	envStructs: Node[];
	closureCounter: number;
	currentFnName: string;
	ss: ScopeStack;
	lastUseCaptures: NameSet;  // Phase F: captures that are last-use (can be moved)
	currentStmts: Node[];      // Phase F: current statement list (for last-use scan)
	currentStmtIdx: number;    // Phase F: current statement index in list
	varTypes: VarTypeEntry[];  // Variable name → type string for env field typing
	capturedIdents: Node[];    // Parallel to captures NameSet: original Identifier nodes with resolvedSym
}

function registerVarType(state: LiftState, name: string, typeStr: string): void {
	state.varTypes.push({ name, typeStr });
}

function lookupVarType(state: LiftState, name: string): string {
	let i = state.varTypes.length - 1;
	while (i >= 0) {
		if (state.varTypes[i].name === name) return state.varTypes[i].typeStr;
		i -= 1;
	}
	return "unknown";
}

// Override lifted function's param/return types from checker-resolved originalNodeType.
// Reference parity: the reference reuses original proc symbol (types already set). We create new node
// via makeFnDecl (string-based), then fix types from the original's concrete type.
function preserveResolvedTypes(fnNode: Node, originalNodeType: Type): void {
	if (originalNodeType === null || fnNode.nodeType === null || fnNode.nodeType.typeChildren === null) return;
	if (originalNodeType.typeChildren !== null) {
		const origCount = originalNodeType.typeChildren.length;
		for (let pi = 0; pi < origCount; pi += 1) {
			if (pi < fnNode.nodeType.typeChildren.length
				&& originalNodeType.typeChildren[pi].kind !== TypeKind.Unknown) {
				fnNode.nodeType.typeChildren[pi] = originalNodeType.typeChildren[pi];
			}
		}
	}
	if (originalNodeType.typeReturn !== null
		&& originalNodeType.typeReturn.kind !== TypeKind.Unknown) {
		fnNode.nodeType.typeReturn = originalNodeType.typeReturn;
	}
}

// Derive type string from resolved nodeType (Reference parity: use resolved symbol types for field typing)
// Used when string annotation is empty but checker has resolved the type.
function typeToEnvStr(t: Type): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Function => "msClosure",
		TypeKind.Struct => {
			// Use explicit local to ensure DRC incref on member access (avoids use-after-free)
			if (t.typeName !== null && t.typeName !== "") {
				const name = t.typeName;
				return name;
			}
			return "";
		},
		TypeKind.Ref | TypeKind.Ptr => {
			// Ref<T>/Ptr<T> store inner type in typeReturn, not typeName
			if (t.typeReturn !== null) return typeToEnvStr(t.typeReturn);
			return "";
		},
		TypeKind.Enum => {
			if (t.typeName !== null && t.typeName !== "") {
				const name = t.typeName;
				return name;
			}
			return "";
		},
		TypeKind.Array => {
			if (t.typeReturn !== null) {
				const elem = typeToEnvStr(t.typeReturn);
				if (elem !== "") { return elem + "[]"; } else { return "unknown[]"; }
			} else { return "unknown[]"; }
		},
		TypeKind.GenericInstance => t.typeName,
		_ => "",
	};
}

function createLiftState(): LiftState {
	const state: LiftState = {
		liftedFunctions: [],
		envStructs: [],
		closureCounter: 0,
		currentFnName: "anon",
		ss: createScopeStack(),
		lastUseCaptures: createNameSet(),
		currentStmts: [],
		currentStmtIdx: 0,
		varTypes: [],
		capturedIdents: [],
	};
	return state;
}

// ===== Phase F: Last-Use Capture Detection =====
// Check if a variable name appears in any statement after index `afterIdx`.
// Used to determine if a capture can be moved instead of copied.

function nodeRefsName(node: Node, varName: string): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		return d.name === varName;
	}
	if (isFuncBoundary(node)) return false;
	let found = false;
	mapChildren(node, (child: Node): Node => {
		if (!found && nodeRefsName(child, varName)) {
			found = true;
		}
		return child;
	});
	return found;
}

function isCaptureLastUse(varName: string, closureIdx: number, stmts: Node[]): boolean {
	let i = closureIdx + 1;
	while (i < stmts.length) {
		if (nodeRefsName(stmts[i], varName)) return false;
		i += 1;
	}
	return true;
}

function computeLastUseCaptures(captures: NameSet, closureIdx: number, stmts: Node[]): NameSet {
	const result: NameSet = createNameSet();
	for (const name of captures.items) {
		if (isCaptureLastUse(name, closureIdx, stmts)) {
			nameSetAdd(result, name);
		}
	}
	return result;
}

// ===== Capture Detection =====
// Detect which outer variables a function body references.
// Walk the body recursively, collecting identifier names that are in outer scopes.
// Module-level state avoids closure capture of value-type arrays (use-after-free in C backend).

let _captureCC: NameSet = createNameSet();
let _captureIdents: Node[] = [];
let _captureSS: ScopeStack = { names: [], funcMarkers: [] };

function detectCaptures(body: Node, ss: ScopeStack, identNodes: Node[]): NameSet {
	_captureCC = createNameSet();
	_captureIdents = identNodes;
	_captureSS = ss;
	collectCaptures(body);
	const result = _captureCC;
	_captureCC = createNameSet();
	_captureIdents = [];
	return result;
}

function collectCaptures(node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (!isBuiltinName(d.name) && !isLocalVar(_captureSS, d.name) && isOuterVar(_captureSS, d.name)) {
			if (!nameSetContains(_captureCC, d.name)) {
				_captureIdents.push(node);
			}
			nameSetAdd(_captureCC, d.name);
		}
		return;
	}
	if (isFuncBoundary(node)) return;
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		collectCaptures(d.initializer);
		defineVar(_captureSS, d.declName);
		return;
	}
	mapChildren(node, (child: Node): Node => { collectCaptures(child); return child; });
}

// ===== Body Rewriting =====
// Replace captured Identifier nodes with _envP.name MemberExpr.

function rewriteNode(node: Node, captures: NameSet, envTypeName: string, envStructType: Type): Node {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (nameSetContains(captures, d.name)) {
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeIdent("_envP", node.location);
			const ptrType = createPtr(envStructType);
			const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: envTypeName }, syntheticToken(node.location));
			cast.nodeType = ptrType;
			const deref = makeHiddenDeref(cast, node.location);
			const member = makeMember(deref, d.name, node.location);
			if (node.nodeType !== null) member.nodeType = node.nodeType;
			return member;
		}
		return node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => rewriteNode(child, captures, envTypeName, envStructType));
	return node;
}

// ===== Closure Lifting =====
// Create env struct + lifted function, return closure pair ObjectLiteral.

// Shared logic for lifting arrow functions and function expressions
// originalNodeType: resolved Type from checker (preserved through lifting)
function liftClosure(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, captures: NameSet, state: LiftState, loc: SourceLocation, originalNodeType: Type): Node {
	state.closureCounter += 1;
	const counter = state.closureCounter;

	const envName = "$Env_" + state.currentFnName + "_" + counter.toString();
	const liftedName = "$lifted_" + state.currentFnName + "_" + counter.toString();

	// Env struct — use concrete Types from captured variables (no TypeReference)
	const envFields: string[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	for (const name of captures.items) {
		envFields.push(name);
		envFieldTypes.push(lookupVarType(state, name));
		// Use actual resolved Type from captured ident (checker-resolved, concrete)
		const orig = findCapturedIdent(name, state.capturedIdents);
		if (orig !== null && orig.nodeType !== null) {
			envResolvedTypes.push(orig.nodeType);
		} else {
			envResolvedTypes.push(unknownType());
		}
	}
	const envDecl = makeInterfaceDeclFromTypes(envName, envFields, envFieldTypes, envResolvedTypes, loc);
	const envStructType = envDecl.nodeType;
	state.envStructs.push(envDecl);

	// Rewrite body to replace captured vars with (*((EnvType*)_envP)).name
	// _envP is void* at runtime; each access casts+derefs to the typed env struct.
	// Must capture return value: for expression bodies (single Identifier), rewriteNode
	// returns a NEW node (MemberExpr); for block bodies, it mutates children in-place.
	let rewrittenBody = rewriteNode(body, captures, envName, envStructType);

	// Expression bodies (arrow without block) need wrapping: expr → { return expr; }
	if (rewrittenBody.kind !== NodeKind.BlockStmt) {
		rewrittenBody = makeBlock([makeReturn(rewrittenBody, loc)], loc);
	}

	// Lifted function params: original params first, then _envP (void*) last
	// Standard reference parity: environment parameter is the LAST parameter
	// void* matches msClosure.env type — no cast needed at call site
	const liftedParams: string[] = [];
	const liftedParamTypes: string[] = [];
	for (const p of params) { liftedParams.push(p); }
	for (const t of paramTypes) { liftedParamTypes.push(t); }
	liftedParams.push("_envP");
	liftedParamTypes.push("void*");

	const fnNode = makeFnDecl(liftedName, liftedParams, liftedParamTypes, rewrittenBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);

	return makeClosurePair(liftedName, envStructType, captures, state.lastUseCaptures, state.capturedIdents, loc);
}

function liftArrow(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as ArrowFunctionData;
	return liftClosure(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, captures, state, node.location, node.nodeType);
}

function liftFuncExpr(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as FunctionExprData;
	return liftClosure(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, captures, state, node.location, node.nodeType);
}

// Non-capturing lift: module-level FunctionDecl + closure pair with env=null.
// Reference parity: plain->closure conversion wraps fn ptr
// in { .ClP_0 = fn, .ClE_0 = NULL }. We emit the same via NF_CLOSURE ObjectLiteral.
// originalNodeType: resolved Type from checker (symbol type preserved)
function liftNonCapturing(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, state: LiftState, loc: SourceLocation, originalNodeType: Type): Node {
	state.closureCounter += 1;
	const liftedName = "$fn_" + state.currentFnName + "_" + state.closureCounter.toString();
	let liftedBody = body;
	if (liftedBody.kind !== NodeKind.BlockStmt) {
		liftedBody = makeBlock([makeReturn(liftedBody, loc)], loc);
	}
	const fnNode = makeFnDecl(liftedName, params, paramTypes, liftedBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);
	// Wrap in closure pair { fn: liftedName, env: null } so codegen emits
	// (msClosure){ .fn = (void*)ptr, .env = NULL } instead of raw function pointer.
	return wrapFnAsClosure(makeIdent(liftedName, loc), loc);
}

// Reference parity: look up original Identifier node for a captured name
// to preserve resolvedSym (needed for codegen name mangling).
function findCapturedIdent(name: string, capturedIdents: Node[]): Node {
	for (const n of capturedIdents) {
		const d = n.data as IdentifierData;
		if (d.name === name) return n;
	}
	return null as unknown as Node;
}

// Wrap a raw function Identifier in a closure pair { fn: ident, env: null }.
// Reference parity: plain->closure wraps fn ptr in { ClP_0, ClE_0=NULL }.
function wrapFnAsClosure(ident: Node, loc: SourceLocation): Node {
	const wrapKeys: string[] = [];
	wrapKeys.push("fn");
	wrapKeys.push("env");
	const wrapVals: Node[] = [];
	wrapVals.push(ident);
	wrapVals.push(makeNull(loc));
	const pair = makeObjectLiteral(wrapKeys, wrapVals, loc);
	pair.flags = pair.flags | NodeFlag.Closure;
	return pair;
}

function makeClosurePair(liftedName: string, envStructType: Type, captures: NameSet, lastUseCaptures: NameSet, capturedIdents: Node[], loc: SourceLocation): Node {
	const envKeys: string[] = [];
	const envValues: Node[] = [];
	for (const name of captures.items) {
		envKeys.push(name);
		// Create Identifier with resolvedSym from original node
		let ident = makeIdent(name, loc);
		const orig = findCapturedIdent(name, capturedIdents);
		if (orig !== null && orig.resolvedSym !== null) {
			ident.resolvedSym = orig.resolvedSym;
			ident.nodeType = orig.nodeType;
		}
		// Captured function declarations: wrap in closure pair so codegen emits
		// (msClosure){ .fn = ..., .env = NULL } instead of raw function pointer.
		// Only wrap SymbolKind.Function (raw fn ptrs), NOT SymbolKind.Variable
		// (closure variables are already msClosure — wrapping them double-wraps).
		const isFnCapture = orig !== null && orig.resolvedSym !== null
			&& orig.resolvedSym.symbolKind === SymbolKind.Function;
		let envVal: Node = ident;
		if (isFnCapture) {
			envVal = wrapFnAsClosure(ident, loc);
		}
		// Phase F: move last-use captures instead of copying
		if (nameSetContains(lastUseCaptures, name)) {
			envValues.push(makeMoveExpr(envVal, loc));
		} else {
			envValues.push(envVal);
		}
	}
	const envObj = makeObjectLiteral(envKeys, envValues, loc);
	// Set nodeType so codegen knows the env struct type for heap allocation
	envObj.nodeType = envStructType;

	const closureKeys: string[] = [];
	closureKeys.push("fn");
	closureKeys.push("env");
	const closureValues: Node[] = [];
	closureValues.push(makeIdent(liftedName, loc));
	closureValues.push(envObj);
	const pair = makeObjectLiteral(closureKeys, closureValues, loc);
	pair.flags = pair.flags | NodeFlag.Closure;
	return pair;
}

// ===== Main Walk =====
// Single top-down recursive walk. When encountering a closure (ArrowFunction/FunctionExpr),
// detect captures and immediately lift if captures found.

function walkLift(node: Node, state: LiftState): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			const savedStmts = state.currentStmts;
			const savedIdx = state.currentStmtIdx;
			state.currentStmts = d.programStmts;
			let pi = 0;
			while (pi < d.programStmts.length) {
				state.currentStmtIdx = pi;
				walkLift(d.programStmts[pi], state);
				pi += 1;
			}
			state.currentStmts = savedStmts;
			state.currentStmtIdx = savedIdx;
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			const savedStmts = state.currentStmts;
			const savedIdx = state.currentStmtIdx;
			state.currentStmts = d.statements;
			let si = 0;
			while (si < d.statements.length) {
				state.currentStmtIdx = si;
				walkLift(d.statements[si], state);
				si += 1;
			}
			state.currentStmts = savedStmts;
			state.currentStmtIdx = savedIdx;
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			const savedName = state.currentFnName;
			if (d.fnName !== "") {
				state.currentFnName = d.fnName;
				defineVar(state.ss, d.fnName);
				// Reference parity: captured function refs → closure type
				registerVarType(state, d.fnName, "msClosure");
			}
			// Push function boundary, define params + register types for env field resolution
			// Prefer resolved types from nodeType (handles type aliases like NumFn → Function)
			pushFuncBoundary(state.ss);
			const fnType = node.nodeType;
			let pi = 0;
			while (pi < d.params.length) {
				defineVar(state.ss, d.params[pi]);
				let paramTypeStr = (pi < d.fnParamTypes.length) ? d.fnParamTypes[pi] : "";
				// Reference parity: use resolved type from checker for env field typing
				if (fnType !== null && fnType.typeChildren !== null && pi < fnType.typeChildren.length) {
					const pt = fnType.typeChildren[pi];
					if (pt !== null) {
						const derived = typeToEnvStr(pt);
						if (derived !== "") {
							paramTypeStr = derived;
						}
					}
				}
				if (paramTypeStr !== "") {
					registerVarType(state, d.params[pi], paramTypeStr);
				}
				pi += 1;
			}
			// Walk body — this may transform inner closures
			walkLiftBody(d.fnBody, state);
			popFuncBoundary(state.ss);
			state.currentFnName = savedName;
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			d.initializer = walkOrLift(d.initializer, state);
			defineVar(state.ss, d.declName);
			if (d.declType !== "") {
				registerVarType(state, d.declName, d.declType);
			} else if (node.nodeType !== null) {
				// Reference parity: use resolved type from checker when no annotation
				const derived = typeToEnvStr(node.nodeType);
				if (derived !== "") {
					registerVarType(state, d.declName, derived);
				}
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = walkOrLift(d.expr, state);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			d.argument = walkOrLift(d.argument, state);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = walkOrLift(d.condition, state);
			walkLift(d.consequent, state);
			walkLift(d.alternate, state);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = walkOrLift(d.whileCondition, state);
			walkLift(d.whileBody, state);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkLift(d.tryBody, state);
			if (d.catchName !== "") {
				defineVar(state.ss, d.catchName);
			}
			walkLift(d.catchBody, state);
			walkLift(d.finallyBody, state);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			for (const c of d.switchCases) {
				walkLift(c, state);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const s of d.caseStmts) {
				walkLift(s, state);
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkLift(d.exportedDecl, state);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			if (d.className !== "") {
				defineVar(state.ss, d.className);
			}
			for (const member of d.classBody) {
				walkLift(member, state);
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			pushFuncBoundary(state.ss);
			for (const p of d.methodParams) { defineVar(state.ss, p); }
			walkLiftBody(d.methodBody, state);
			popFuncBoundary(state.ss);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			pushFuncBoundary(state.ss);
			for (const p of d.ctorParams) { defineVar(state.ss, p); }
			walkLiftBody(d.ctorBody, state);
			popFuncBoundary(state.ss);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkLift(d.decoratedNode, state);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkLift(d.callee, state);
			let i = 0;
			while (i < d.arguments.length) {
				const arg = d.arguments[i];
				if (arg.kind === NodeKind.ArrowFunction || arg.kind === NodeKind.FunctionExpr) {
					const lifted = tryLiftClosure(arg, state);
					if (lifted.kind !== arg.kind) {
						d.arguments[i] = lifted;
					}
				} else {
					walkLift(arg, state);
				}
				i += 1;
			}
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.right = walkOrLift(d.right, state);
			walkLift(d.left, state);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = walkOrLift(d.operand, state);
		},
		_ => {},
	};
}

function walkLiftBody(body: Node, state: LiftState): void {
	walkLift(body, state);
}

// Walk a node, lifting closures if it's an ArrowFunction/FunctionExpr with captures.
// Returns the (possibly replaced) node.
function walkOrLift(node: Node, state: LiftState): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) {
		return tryLiftClosure(node, state);
	}
	walkLift(node, state);
	return node;
}

// Try to lift a closure. Returns the original node if no captures, or a closure pair if lifted.
function tryLiftClosure(node: Node, state: LiftState): Node {
	// Detect captures by analyzing the closure body
	pushFuncBoundary(state.ss);

	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		for (const p of d.arrowParams) { defineVar(state.ss, p); }
		state.capturedIdents = [];
		const captures = detectCaptures(d.arrowBody, state.ss, state.capturedIdents);
		popFuncBoundary(state.ss);
		if (captures.items.length > 0) {
			// Phase F: compute which captures are last-use in enclosing scope
			state.lastUseCaptures = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
			return liftArrow(node, captures, state);
		}
		// Non-capturing: lift to module-level FunctionDecl, return Identifier
		return liftNonCapturing(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, state, node.location, node.nodeType);
	} else if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		for (const p of d.funcExprParams) { defineVar(state.ss, p); }
		state.capturedIdents = [];
		const captures = detectCaptures(d.funcExprBody, state.ss, state.capturedIdents);
		popFuncBoundary(state.ss);
		if (captures.items.length > 0) {
			// Phase F: compute which captures are last-use in enclosing scope
			state.lastUseCaptures = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
			return liftFuncExpr(node, captures, state);
		}
		// Non-capturing: lift to module-level FunctionDecl, return Identifier
		return liftNonCapturing(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, state, node.location, node.nodeType);
	} else {
		popFuncBoundary(state.ss);
	}
	return node;
}

// ===== Main Entry Point =====

export function lowerLambda(program: Node, ctx: TransformContext): Node {
	const state = createLiftState();
	walkLift(program, state);

	// Prepend env structs + lifted functions to program
	if (state.envStructs.length === 0 && state.liftedFunctions.length === 0) {
		return program;
	}

	if (program.kind === NodeKind.Program) {
		const d = program.data as ProgramData;
		const newStmts: Node[] = [];
		for (const s of state.envStructs) {
			newStmts.push(s);
		}
		for (const f of state.liftedFunctions) {
			newStmts.push(f);
		}
		for (const s of d.programStmts) {
			newStmts.push(s);
		}
		program.data = { programStmts: newStmts };
	}

	return program;
}

// ===== Tests =====
test "no closures passthrough" { assert stmtCountAfter("const x = 1;", lowerLambda) === 1; }

test "function without capture unchanged" { assert firstStmtKindAfter("function foo(x) { return x; }", lowerLambda) === NodeKind.FunctionDecl; }

test "non-capturing arrow lifted" {
	// Arrow lifted to module-level FunctionDecl + original VariableDecl = 2 stmts
	assert stmtCountAfter("const f = (x) => x + 1;", lowerLambda) === 2;
	assert firstStmtKindAfter("const f = (x) => x + 1;", lowerLambda) === NodeKind.FunctionDecl;
}

test "non-capturing arrow in function lifted" {
	// Inner arrow lifted to program level: lifted fn + outer fn = 2 stmts
	assert stmtCountAfter("function f(x) { const g = (y) => y + 1; }", lowerLambda) === 2;
}

test "arrow with capture generates 3 stmts" {
	// function outer() { let x = 1; const f = () => x; }
	// → env struct + lifted fn + original fn = 3 stmts
	assert stmtCountAfter("function outer() { let x = 1; const f = () => x; }", lowerLambda) === 3;
}

test "env struct is first stmt" { assert firstStmtKindAfter("function outer() { let x = 1; const f = () => x; }", lowerLambda) === NodeKind.InterfaceDecl; }

test "builtin name not captured" {
	// Arrow referencing builtin is non-capturing, but still lifted: lifted fn + outer fn = 2
	assert stmtCountAfter("function f() { const g = () => console; }", lowerLambda) === 2;
}

test "multiple captures one env" { assert stmtCountAfter("function f() { let a = 1; let b = 2; const g = () => a + b; }", lowerLambda) === 3; }

test "non-capturing function expr lifted" {
	assert stmtCountAfter("const f = function(x) { return x + 1; };", lowerLambda) === 2;
	assert firstStmtKindAfter("const f = function(x) { return x + 1; };", lowerLambda) === NodeKind.FunctionDecl;
}

test "isCaptureLastUse: var not used after closure" {
	// Simulate: [let x = 1, const f = () => x]  — x not used after index 1
	const result = parseInput("function f() { let x = 1; const g = () => x; }");
	if (result.ok) {
		const stmts = getStmts(result.value);
		// In function body
		const fd = stmts[0].data as FunctionDeclData;
		const bd = fd.fnBody.data as BlockStmtData;
		// x captured at index 1, not used at index 2+ (no stmts after)
		assert isCaptureLastUse("x", 1, bd.statements);
	}
}

test "isCaptureLastUse: var used after closure" {
	const result = parseInput("function f() { let x = 1; const g = () => x; return x; }");
	if (result.ok) {
		const stmts = getStmts(result.value);
		const fd = stmts[0].data as FunctionDeclData;
		const bd = fd.fnBody.data as BlockStmtData;
		// x captured at index 1, but used in return at index 2
		assert !isCaptureLastUse("x", 1, bd.statements);
	}
}
