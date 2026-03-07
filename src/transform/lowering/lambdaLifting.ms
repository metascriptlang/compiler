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

import {
	Node, NodeKind, SourceLocation, NodeFlag, createNode,
	ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData,
	FunctionExprData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData,
	SwitchStmtData, SwitchCaseData,
	ExprStmtData, ReturnStmtData,
	BinaryExprData, CallExprData,
	IdentifierData,
} from "../../ast/node";
import { TransformContext, NameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeIdent, makeMember, makeMoveExpr, makeReturn, makeBlock,
	makeFnDecl, makeInterfaceDecl, makeObjectLiteral, makeHiddenDeref,
	syntheticToken,
} from "../util";
import { TypeKind, createTypeRef, createPtr } from "../../checker/types";
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

function createLiftState(): LiftState {
	const state: LiftState = {
		liftedFunctions: [],
		envStructs: [],
		closureCounter: 0,
		currentFnName: "anon",
		ss: createScopeStack(),
		lastUseCaptures: [],
		currentStmts: [],
		currentStmtIdx: 0,
		varTypes: [],
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
	const result: NameSet = [];
	for (const name of captures) {
		if (isCaptureLastUse(name, closureIdx, stmts)) {
			nameSetAdd(result, name);
		}
	}
	return result;
}

// ===== Capture Detection =====
// Detect which outer variables a function body references.
// Walk the body recursively, collecting identifier names that are in outer scopes.
// NOTE: string[] is VALUE TYPE in MetaScript — wrap in interface for mutation propagation.

function detectCaptures(body: Node, ss: ScopeStack): NameSet {
	const cc: NameSet = [];
	collectCaptures(body, ss, cc);
	return cc;
}

function collectCaptures(node: Node, ss: ScopeStack, cc: NameSet): void {
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (!isBuiltinName(d.name) && !isLocalVar(ss, d.name) && isOuterVar(ss, d.name)) {
			nameSetAdd(cc, d.name);
		}
		return;
	}
	if (isFuncBoundary(node)) return;
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		collectCaptures(d.initializer, ss, cc);
		defineVar(ss, d.declName);
		return;
	}
	mapChildren(node, (child: Node): Node => { collectCaptures(child, ss, cc); return child; });
}

// ===== Body Rewriting =====
// Replace captured Identifier nodes with _envP.name MemberExpr.

function rewriteNode(node: Node, captures: NameSet, envTypeName: string): Node {
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (nameSetContains(captures, d.name)) {
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeIdent("_envP", node.location);
			const ptrType = createPtr(createTypeRef(envTypeName));
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
	mapChildren(node, (child: Node): Node => rewriteNode(child, captures, envTypeName));
	return node;
}

// ===== Closure Lifting =====
// Create env struct + lifted function, return closure pair ObjectLiteral.

// Shared logic for lifting arrow functions and function expressions
function liftClosure(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, captures: NameSet, state: LiftState, loc: SourceLocation): Node {
	state.closureCounter += 1;
	const counter = state.closureCounter;

	const envName = "$Env_" + state.currentFnName + "_" + counter.toString();
	const liftedName = "$lifted_" + state.currentFnName + "_" + counter.toString();

	// Env struct — resolve captured variable types (Standard reference pattern)
	const envFields: string[] = [];
	const envFieldTypes: string[] = [];
	for (const name of captures) {
		envFields.push(name);
		envFieldTypes.push(lookupVarType(state, name));
	}
	state.envStructs.push(makeInterfaceDecl(envName, envFields, envFieldTypes, loc));

	// Rewrite body to replace captured vars with (*((EnvType*)_envP)).name
	// _envP is void* at runtime; each access casts+derefs to the typed env struct.
	// Must capture return value: for expression bodies (single Identifier), rewriteNode
	// returns a NEW node (MemberExpr); for block bodies, it mutates children in-place.
	let rewrittenBody = rewriteNode(body, captures, envName);

	// Expression bodies (arrow without block) need wrapping: expr → { return expr; }
	if (rewrittenBody.kind !== NodeKind.BlockStmt) {
		rewrittenBody = makeBlock([makeReturn(rewrittenBody, loc)], loc);
	}

	// Lifted function params: _envP (void*) first, then original params
	// env-first matches closure call convention: callee.fn(callee.env, args...)
	// void* matches msClosure.env type — no cast needed at call site
	const liftedParams: string[] = ["_envP"];
	const liftedParamTypes: string[] = ["void*"];
	for (const p of params) { liftedParams.push(p); }
	for (const t of paramTypes) { liftedParamTypes.push(t); }

	state.liftedFunctions.push(makeFnDecl(liftedName, liftedParams, liftedParamTypes, rewrittenBody, flags, returnType, loc));

	return makeClosurePair(liftedName, envName, captures, state.lastUseCaptures, loc);
}

function liftArrow(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as ArrowFunctionData;
	return liftClosure(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, captures, state, node.location);
}

function liftFuncExpr(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as FunctionExprData;
	return liftClosure(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, captures, state, node.location);
}

// Non-capturing lift: no env struct, no closure pair — just a module-level FunctionDecl + Identifier ref.
function liftNonCapturing(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, state: LiftState, loc: SourceLocation): Node {
	state.closureCounter += 1;
	const liftedName = "$fn_" + state.currentFnName + "_" + state.closureCounter.toString();
	let liftedBody = body;
	if (liftedBody.kind !== NodeKind.BlockStmt) {
		liftedBody = makeBlock([makeReturn(liftedBody, loc)], loc);
	}
	state.liftedFunctions.push(makeFnDecl(liftedName, params, paramTypes, liftedBody, flags, returnType, loc));
	return makeIdent(liftedName, loc);
}

function makeClosurePair(liftedName: string, envTypeName: string, captures: NameSet, lastUseCaptures: NameSet, loc: SourceLocation): Node {
	const envKeys: string[] = [];
	const envValues: Node[] = [];
	for (const name of captures) {
		envKeys.push(name);
		// Phase F: move last-use captures instead of copying
		if (nameSetContains(lastUseCaptures, name)) {
			envValues.push(makeMoveExpr(makeIdent(name, loc), loc));
		} else {
			envValues.push(makeIdent(name, loc));
		}
	}
	const envObj = makeObjectLiteral(envKeys, envValues, loc);
	// Set nodeType so codegen knows the env struct type for heap allocation
	envObj.nodeType = createTypeRef(envTypeName);

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
			}
			// Push function boundary, define params + register types for env field resolution
			// Prefer resolved types from nodeType (handles type aliases like NumFn → Function)
			pushFuncBoundary(state.ss);
			const fnType = node.nodeType;
			let pi = 0;
			while (pi < d.params.length) {
				defineVar(state.ss, d.params[pi]);
				let paramTypeStr = (pi < d.fnParamTypes.length) ? d.fnParamTypes[pi] : "";
				// If checker resolved Function type for this param, use "msClosure" directly.
				// Also check TypeReference with "=>" annotation (unresolved type alias).
				if (fnType !== null && fnType.typeChildren !== null && pi < fnType.typeChildren.length) {
					const pt = fnType.typeChildren[pi];
					if (pt !== null && pt.kind === TypeKind.Function) {
						paramTypeStr = "msClosure";
					} else if (pt !== null && pt.kind === TypeKind.TypeReference) {
						const tn = pt.typeName;
						if (tn.length > 0 && (tn.indexOf("=>", 0) >= 0 || tn.charAt(0) === "(")) {
							paramTypeStr = "msClosure";
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
			walkLift(d.consequent, state);
			walkLift(d.alternate, state);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
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
		const captures = detectCaptures(d.arrowBody, state.ss);
		popFuncBoundary(state.ss);
		if (captures.length > 0) {
			// Phase F: compute which captures are last-use in enclosing scope
			state.lastUseCaptures = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
			return liftArrow(node, captures, state);
		}
		// Non-capturing: lift to module-level FunctionDecl, return Identifier
		return liftNonCapturing(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, state, node.location);
	} else if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		for (const p of d.funcExprParams) { defineVar(state.ss, p); }
		const captures = detectCaptures(d.funcExprBody, state.ss);
		popFuncBoundary(state.ss);
		if (captures.length > 0) {
			// Phase F: compute which captures are last-use in enclosing scope
			state.lastUseCaptures = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
			return liftFuncExpr(node, captures, state);
		}
		// Non-capturing: lift to module-level FunctionDecl, return Identifier
		return liftNonCapturing(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, state, node.location);
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
		d.programStmts = newStmts;
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
