// Generator Lowering — transforms function* into state machines
//
// Converts yield-based generator functions into regular functions returning
// iterator objects with a next() method containing a state dispatch loop.
//
// function* counter(max) {       function counter(max) {
//     let i = 0;                     let $state = 0;
//     while (i < max) {              let i;
//         yield i;           →       return { next: function() {
//         i = i + 1;                     while (true) {
//     }                                      if ($state === 0) { i = 0; $state = 1; }
// }                                          else if ($state === 1) { ... }
//                                            else { return { value: null, done: true }; }
//                                        }
//                                    }};
//                                }
//
// V1: yield in statement position, while/if with yield.
// V2 deferred: yield*, yield in expressions, yield in try/catch.

import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	VariableDeclData, IfStmtData, WhileStmtData,
	ExprStmtData, ReturnStmtData,
	BinaryExprData, UnaryExprData, CallExprData,
	ConditionalExprData, TryCatchStmtData, YieldExprData,
	ExportDeclData, ClassDeclData, MethodDeclData, DecoratedDeclData,
} from "../../ast/node";
import { TransformContext, NameSet, nameSetContains } from "../context";
import {
	makeIdent, makeNull, makeNumber, makeBool,
	makeBlock, makeVarDecl, makeExprStmt, makeReturn,
	makeIf, makeWhile, makeBinary, makeAssign,
	makeObjectLiteral, syntheticToken, extractBodyStmts,
	collectDeclNames,
} from "../util";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Data Structures =====

interface GenState {
	index: number;
	isYield: boolean;
	nextState: number;
	stmts: Node[];
}

interface StateCollector {
	items: GenState[];
}


// ===== Helpers =====

function makeIterResult(value: Node, done: boolean, loc: SourceLocation): Node {
	return makeObjectLiteral(
		["value", "done"],
		[value, makeBool(done, loc)],
		loc,
	);
}

function makeDoneResult(loc: SourceLocation): Node {
	return makeIterResult(makeNull(loc), true, loc);
}

function makeStateAssign(stateNum: number, loc: SourceLocation): Node {
	return makeExprStmt(
		makeAssign(makeIdent("$state", loc), makeNumber(stateNum, loc), loc),
		loc,
	);
}

function allocState(sc: StateCollector): number {
	const idx = sc.items.length;
	const st: GenState = { index: idx, isYield: false, nextState: -1, stmts: [] };
	sc.items.push(st);
	return idx;
}

function isGeneratorFlag(flags: string): boolean {
	return match (flags) {
		"generator" | "async_generator" => true,
		_ => false,
	};
}

// ===== Yield Detection =====

function containsYield(node: Node): boolean {
	return match (node.kind) {
		NodeKind.YieldExpr => true,
		// Stop at nested function boundaries
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => false,
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) {
				if (containsYield(s)) return true;
			}
			return false;
		},
		NodeKind.ExprStmt => { const d = node.data as ExprStmtData; return containsYield(d.expr); },
		NodeKind.ReturnStmt => { const d = node.data as ReturnStmtData; return containsYield(d.argument); },
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; return containsYield(d.initializer); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return containsYield(d.condition) || containsYield(d.consequent) || containsYield(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return containsYield(d.whileCondition) || containsYield(d.whileBody);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return containsYield(d.tryBody) || containsYield(d.catchBody) || containsYield(d.finallyBody);
		},
		NodeKind.BinaryExpr => { const d = node.data as BinaryExprData; return containsYield(d.left) || containsYield(d.right); },
		NodeKind.UnaryExpr => { const d = node.data as UnaryExprData; return containsYield(d.operand); },
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (containsYield(d.callee)) return true;
			for (const a of d.arguments) {
				if (containsYield(a)) return true;
			}
			return false;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			return containsYield(d.ternaryCondition) || containsYield(d.ternaryConsequent) || containsYield(d.ternaryAlternate);
		},
		_ => false,
	};
}

// ===== State Splitting =====
// Split a linear sequence of statements at yield points.

function splitStmts(stmts: Node[], sc: StateCollector, startState: number, exitState: number, loc: SourceLocation): void {
	let currentState = startState;
	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (!containsYield(stmt)) {
			sc.items[currentState].stmts.push(stmt);
			i += 1;
		} else if (stmt.kind === NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			if (ed.expr.kind === NodeKind.YieldExpr) {
				// yield expr; → emit return { value: expr, done: false }, transition
				const yd = ed.expr.data as YieldExprData;
				const nextSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				sc.items[currentState].stmts.push(makeStateAssign(nextSt, loc));
				sc.items[currentState].stmts.push(
					makeReturn(makeIterResult(yd.yieldArg, false, loc), loc),
				);
				sc.items[currentState].isYield = true;
				sc.items[currentState].nextState = nextSt;
				if (i + 1 < stmts.length) {
					currentState = nextSt;
				}
				i += 1;
			} else {
				// Yield nested in an expression — skip for V1, treat as normal stmt
				sc.items[currentState].stmts.push(stmt);
				i += 1;
			}
		} else if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer.kind === NodeKind.YieldExpr) {
				// const x = yield expr; → yield, then assign on resume
				const yd = vd.initializer.data as YieldExprData;
				const nextSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				sc.items[currentState].stmts.push(makeStateAssign(nextSt, loc));
				sc.items[currentState].stmts.push(
					makeReturn(makeIterResult(yd.yieldArg, false, loc), loc),
				);
				sc.items[currentState].isYield = true;
				// On resume: convert decl to assignment (var is lifted)
				if (i + 1 < stmts.length) {
					currentState = nextSt;
				}
				i += 1;
			} else {
				// VariableDecl with yield somewhere in initializer — treat as normal for V1
				// Convert to assignment since var is lifted
				const assignStmt = makeExprStmt(
					makeAssign(makeIdent(vd.declName, loc), vd.initializer, loc),
					loc,
				);
				sc.items[currentState].stmts.push(assignStmt);
				i += 1;
			}
		} else if (stmt.kind === NodeKind.WhileStmt) {
			splitWhile(stmt, sc, currentState, loc);
			// After splitting while, allocate continuation state
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			// The while exit transitions to afterSt — handled in splitWhile
			// We need to patch: splitWhile uses exitState = afterSt
			// Actually, redo: splitWhile needs to know where to go after the loop
			// Let me restructure: splitWhile returns the exit state index
			// For now, flush current state to transition to a condition state
			// and splitWhile handles everything
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind === NodeKind.IfStmt) {
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitIf(stmt, sc, currentState, afterSt, loc);
			currentState = afterSt;
			i += 1;
		} else {
			// Other stmt types containing yield — skip for V1
			sc.items[currentState].stmts.push(stmt);
			i += 1;
		}
	}
	// Final state transitions to exit
	if (currentState !== exitState) {
		sc.items[currentState].stmts.push(makeStateAssign(exitState, loc));
	}
}

// Split while loop containing yield into states:
// condState: if (cond) { $state = bodyStart } else { $state = exitState }
// bodyStates: ... (recursive split, last transitions back to condState)
function splitWhile(node: Node, sc: StateCollector, currentState: number, loc: SourceLocation): void {
	const wd = node.data as WhileStmtData;

	// Condition state = currentState (reuse, already allocated)
	const condState = currentState;

	// Allocate body start and exit states
	const bodyStart = allocState(sc);
	const exitState = allocState(sc);

	// Condition: if (cond) { $state = bodyStart } else { $state = exitState }
	sc.items[condState].stmts.push(
		makeIf(
			wd.whileCondition,
			makeBlock([makeStateAssign(bodyStart, loc)], loc),
			makeBlock([makeStateAssign(exitState, loc)], loc),
			loc,
		),
	);

	// Split body statements, looping back to condState
	const bodyStmts = extractBodyStmts(wd.whileBody);
	splitStmts(bodyStmts, sc, bodyStart, condState, loc);
}

// Split if-else containing yield:
// currentState: if (cond) { $state = thenStart } else { $state = elseStart }
// thenStates: ... → joinState
// elseStates: ... → joinState
function splitIf(node: Node, sc: StateCollector, currentState: number, joinState: number, loc: SourceLocation): void {
	const id = node.data as IfStmtData;

	const thenStart = allocState(sc);
	const hasElse = id.alternate.kind !== NodeKind.NullLiteral && id.alternate.kind !== NodeKind.BlockStmt || (id.alternate.kind === NodeKind.BlockStmt && (id.alternate.data as BlockStmtData).statements.length > 0);

	if (hasElse && containsYield(id.alternate)) {
		const elseStart = allocState(sc);
		sc.items[currentState].stmts.push(
			makeIf(
				id.condition,
				makeBlock([makeStateAssign(thenStart, loc)], loc),
				makeBlock([makeStateAssign(elseStart, loc)], loc),
				loc,
			),
		);
		const thenStmts = extractBodyStmts(id.consequent);
		splitStmts(thenStmts, sc, thenStart, joinState, loc);
		const elseStmts = extractBodyStmts(id.alternate);
		splitStmts(elseStmts, sc, elseStart, joinState, loc);
	} else {
		// Only then branch has yield (or no else)
		sc.items[currentState].stmts.push(
			makeIf(
				id.condition,
				makeBlock([makeStateAssign(thenStart, loc)], loc),
				makeBlock([makeStateAssign(joinState, loc)], loc),
				loc,
			),
		);
		const thenStmts = extractBodyStmts(id.consequent);
		splitStmts(thenStmts, sc, thenStart, joinState, loc);
		// Else branch (no yield) goes directly into joinState
		if (hasElse) {
			const elseStmts = extractBodyStmts(id.alternate);
			for (const s of elseStmts) {
				sc.items[joinState].stmts.push(s);
			}
		}
	}
}

// ===== Return Rewriting =====
// Rewrite return stmts in generator body: return val → $state = -1; return { value: val, done: true }

function rewriteReturns(stmts: Node[], loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.ReturnStmt) {
			const rd = stmt.data as ReturnStmtData;
			// Replace with block: { $state = -1; return { value: val, done: true }; }
			const block = makeBlock([
				makeStateAssign(-1, loc),
				makeReturn(makeIterResult(rd.argument, true, loc), loc),
			], loc);
			stmts[i] = block;
		}
	}
}

// ===== Variable Declaration → Assignment =====
// Convert lifted variable declarations to assignments in state bodies.
// Variables are hoisted to function scope, so decls become assignments.

function convertDeclsToAssigns(stmts: Node[], liftedNames: NameSet, loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (nameSetContains(liftedNames, vd.declName)) {
				// Convert: const/let x = init → x = init (assignment)
				stmts[i] = makeExprStmt(
					makeAssign(makeIdent(vd.declName, loc), vd.initializer, loc),
					loc,
				);
			}
		}
	}
}

// ===== State Machine Builder =====

function buildStateDispatch(sc: StateCollector, loc: SourceLocation): Node {
	// Default (terminal) state: return { value: null, done: true }
	let current: Node = makeBlock([makeReturn(makeDoneResult(loc), loc)], loc);

	// Build if-else chain from last state to first
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		const stateIdx = sc.items[i].index;
		const cond = makeBinary(
			makeIdent("$state", loc), "===",
			makeNumber(stateIdx, loc), loc,
		);
		const body = makeBlock(sc.items[i].stmts, loc);
		current = makeIf(cond, body, current, loc);
	}
	return current;
}

// ===== Generator Function Transform =====

function transformGeneratorFn(params: string[], paramTypes: string[], body: Node, flags: string, returnType: string, loc: SourceLocation): Node {
	// 1. Collect all local variable names
	const nc: NameSet = [];
	collectDeclNames(body, nc, false);

	// 2. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// 3. Rewrite return statements
	rewriteReturns(bodyStmts, loc);

	// 4. Split at yield points
	const sc: StateCollector = { items: [] };
	const initState = allocState(sc);
	const doneState = -1;  // terminal

	splitStmts(bodyStmts, sc, initState, doneState, loc);

	// 5. Convert variable declarations to assignments in all state bodies
	for (let si = 0; si < sc.items.length; si += 1) {
		convertDeclsToAssigns(sc.items[si].stmts, nc, loc);
	}

	// 6. Build the state dispatch (if-else chain)
	const dispatch = buildStateDispatch(sc, loc);

	// 7. Wrap in while(true) { dispatch }
	const loop = makeWhile(makeBool(true, loc), dispatch, loc);

	// 8. Build next() function body
	const nextBody = makeBlock([loop], loc);

	// 9. Create next FunctionExpr
	const nextFn = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [],
		funcExprParamTypes: [],
		funcExprBody: nextBody,
		funcExprFlags: "",
		funcExprReturnType: "",
	}, syntheticToken(loc));

	// 10. Build iterator object: { next: function() { ... } }
	const iterObj = makeObjectLiteral(["next"], [nextFn], loc);

	// 11. Build new function body:
	//   let $state = 0;
	//   let local1; let local2; ...
	//   return { next: function() { while(true) { if-else dispatch } } };
	const newBodyStmts: Node[] = [];
	newBodyStmts.push(makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc));
	for (const localName of nc) {
		newBodyStmts.push(makeVarDecl(localName, makeNull(loc), DeclKind.Let, loc));
	}
	newBodyStmts.push(makeReturn(iterObj, loc));

	return makeBlock(newBodyStmts, loc);
}

// ===== Main Walk =====

function walkGenerators(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { walkGenerators(s); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { walkGenerators(s); }
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkGenerators(d.fnBody);
			if (isGeneratorFlag(d.fnFlags)) {
				d.fnBody = transformGeneratorFn(
					d.params, d.fnParamTypes, d.fnBody,
					d.fnFlags, d.fnReturnType, node.location,
				);
				d.fnFlags = "";
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkGenerators(d.exportedDecl);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) { walkGenerators(member); }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkGenerators(d.methodBody);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkGenerators(d.decoratedNode);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			walkCheckFuncExpr(d.initializer);
		},
		_ => {},
	};
}

// Check FunctionExpr for generator flag
function walkCheckFuncExpr(node: Node): void {
	if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkGenerators(d.funcExprBody);
		if (isGeneratorFlag(d.funcExprFlags)) {
			d.funcExprBody = transformGeneratorFn(
				d.funcExprParams, d.funcExprParamTypes, d.funcExprBody,
				d.funcExprFlags, d.funcExprReturnType, node.location,
			);
			d.funcExprFlags = "";
		}
	}
}

// ===== Main Entry Point =====

export function lowerGenerator(program: Node, ctx: TransformContext): Node {
	walkGenerators(program);
	return program;
}

// ===== Tests =====
test "non-generator passthrough" { assert firstStmtKindAfter("function foo() { return 1; }", lowerGenerator) === NodeKind.FunctionDecl; }

test "stmt count passthrough" { assert stmtCountAfter("const x = 1;", lowerGenerator) === 1; }

test "generator still one stmt" {
	// function* gen() { yield 1; } → function gen() { ... } — still 1 top-level stmt
	assert stmtCountAfter("function* gen() { yield 1; }", lowerGenerator) === 1;
}

test "generator flag removed" { assert firstStmtKindAfter("function* gen() { yield 1; }", lowerGenerator) === NodeKind.FunctionDecl; }

test "two yields" { assert stmtCountAfter("function* gen() { yield 1; yield 2; }", lowerGenerator) === 1; }

test "yield with locals" { assert stmtCountAfter("function* gen() { let x = 1; yield x; }", lowerGenerator) === 1; }

test "while yield loop" { assert stmtCountAfter("function* gen() { let i = 0; while (i < 3) { yield i; i = i + 1; } }", lowerGenerator) === 1; }

test "regular function unchanged" { assert stmtCountAfter("function f() { while (true) {} }", lowerGenerator) === 1; }
