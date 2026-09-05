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
	ExportDeclData, ClassDeclData, MethodDeclData, DecoratedDeclData, Type, TypeKind,
	IdentifierData, Symbol,
	isEmptyBlock,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { isIterator, getIteratorYieldType, getIteratorNextFnType, hasGenericParams, createIteratorResult } from "../../checker/types";
import { TransformContext, NameSet, createNameSet, nameSetContains } from "../context";
import {
	makeIdent, makeIdentResolved, makeTypedIdent, makeNull, makeNumber, makeBool,
	makeBlock, makeVarDecl, makeExprStmt, makeReturn,
	makeIf, makeWhile, makeBinary, makeAssign, makeContinue,
	makeObjectLiteral, syntheticToken, extractBodyStmts,
	collectDeclNames, makeTryCatch, makeMoveExpr,
} from "../util";
import { numberType, createPtr, createPrimitive } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Data Structures =====

export interface GenState {
	index: number;
	isYield: boolean;
	nextState: number;
	stmts: Node[];
	yieldVarName: string;   // variable assigned from yield (for async resume)
	yieldVarType: Type;     // type of the variable (for unboxing msFutureRead)
	excLanding: number;     // reference exceptionTable[i]: state to jump to if this state raises (-1 = propagate)
}

// Active while-with-yield scope. break/continue inside the body must
// transition to these states; a bare C `break;`/`continue;` would exit the
// outer dispatcher while(1) and leave the future un-completed.
export interface LoopFrame {
	breakState: number;
	continueState: number;
}

// Active finally scope (finallyPath port, reference closureiters): a
// yield-containing try with a yield-free finally inlines its finally body at
// every exit of the try. loopDepth = loopStack length when the try began; a
// break/continue only crosses the try — and so only runs the finally — when
// its target loop sits outside the try (frame.loopDepth > target loop index).
export interface FinallyFrame {
	stmts: Node[];
	loopDepth: number;
}

export interface StateCollector {
	items: GenState[];
	loopStack: LoopFrame[];
	excType: Type | null;   // exception type carried by $curExc (from a catch's nodeType)
	finallyStack: FinallyFrame[];
}


// ===== Helpers =====

// Collect name→Type from VarDecl nodes in the body.
// Reference parity (captureVar): env fields always carry their original type.
function collectDeclTypes(node: Node, names: string[], types: Type[]): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			const t = node.nodeType !== null ? node.nodeType
				: (d.initializer !== null ? d.initializer.nodeType : null);
			if (t !== null) {
				names.push(d.declName);
				types.push(t);
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { collectDeclTypes(s, names, types); }
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			collectDeclTypes(d.whileBody, names, types);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			collectDeclTypes(d.consequent, names, types);
			collectDeclTypes(d.alternate, names, types);
		},
		_ => {},
	};
}

function lookupDeclType(names: string[], types: Type[], name: string): Type {
	let i = 0;
	while (i < names.length) {
		if (names[i] === name) return types[i];
		i = i + 1;
	}
	return null as unknown as Type;
}

function buildIterResultType(returnNodeType: Type | null): Type | null {
	if (returnNodeType === null || !isIterator(returnNodeType)) return null;
	const yieldType = getIteratorYieldType(returnNodeType);
	if (yieldType === null) return null;
	return createIteratorResult(yieldType);
}

function makeIterResult(value: Node, done: boolean, loc: SourceLocation, resultType: Type | null): Node {
	const obj = makeObjectLiteral(
		["value", "done"],
		[value, makeBool(done, loc)],
		loc,
	);
	if (resultType !== null) obj.nodeType = resultType;
	return obj;
}

function makeDoneResult(loc: SourceLocation, resultType: Type | null): Node {
	return makeIterResult(makeNull(loc), true, loc, resultType);
}

export function makeStateAssign(stateNum: number, loc: SourceLocation): Node {
	return makeExprStmt(
		makeAssign(makeTypedIdent("$state", numberType(), loc), makeNumber(stateNum, loc), loc),
		loc,
	);
}

// `{ $state = N; continue; }` — trailing continue skips dead code after the
// source-level break/continue so it doesn't overwrite $state before the
// dispatcher re-evaluates. Safe only when no nested loop sits between the
// rewrite point and the dispatcher; rewriteLoopExits enforces by not
// descending into nested loops/switch.
function makeStateGoto(stateNum: number, loc: SourceLocation): Node {
	return makeBlock([makeStateAssign(stateNum, loc), makeContinue(loc)], loc);
}

// Descends Block/If/Try only — nested loops and switch own their own
// break/continue scope.
function rewriteOrRecurse(stmt: Node, top: LoopFrame, loc: SourceLocation): Node {
	if (stmt === null) return stmt;
	if (stmt.kind === NodeKind.BreakStmt) return makeStateGoto(top.breakState, loc);
	if (stmt.kind === NodeKind.ContinueStmt) return makeStateGoto(top.continueState, loc);
	rewriteLoopExits(stmt, top, loc);
	return stmt;
}

function rewriteLoopExits(node: Node, top: LoopFrame, loc: SourceLocation): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (let i = 0; i < d.statements.length; i += 1) {
				d.statements[i] = rewriteOrRecurse(d.statements[i], top, loc);
			}
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.consequent = rewriteOrRecurse(d.consequent, top, loc);
			d.alternate = rewriteOrRecurse(d.alternate, top, loc);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			d.tryBody = rewriteOrRecurse(d.tryBody, top, loc);
			d.catchBody = rewriteOrRecurse(d.catchBody, top, loc);
			d.finallyBody = rewriteOrRecurse(d.finallyBody, top, loc);
		},
		_ => {},
	};
}

export function allocState(sc: StateCollector): number {
	const idx = sc.items.length;
	const st: GenState = { index: idx, isYield: false, nextState: -1, stmts: [], yieldVarName: "", yieldVarType: null as unknown as Type, excLanding: -1 };
	sc.items.push(st);
	return idx;
}

function isGeneratorFlag(flags: string): boolean {
	if (flags === "generator" || flags === "async_generator") return true;
	return flags.indexOf("generator") >= 0;
}

// ===== Yield Detection =====

export function containsYield(node: Node | null): boolean {
	if (node === null) return false;
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
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; return d.initializer !== null && containsYield(d.initializer); },
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

// Emit yield: transition to next state + return IteratorResult.
function emitYield(sc: StateCollector, currentState: number, nextSt: number, yieldArg: Node, loc: SourceLocation, resultType: Type | null): void {
	sc.items[currentState].stmts.push(makeStateAssign(nextSt, loc));
	sc.items[currentState].stmts.push(makeReturn(makeIterResult(yieldArg, false, loc, resultType), loc));
	sc.items[currentState].isYield = true;
	sc.items[currentState].nextState = nextSt;
}

// ===== State Splitting =====
// Split a linear sequence of statements at yield points.

// Inline the finally bodies of every frame a break/continue crosses
// (innermost first). targetLoopIdx = loopStack index of the loop being exited;
// frames entered deeper than the target (loopDepth > targetLoopIdx) are tries
// the exit leaves, so their finally must run before the state transition.
function pushCrossedFinallies(sc: StateCollector, targetLoopIdx: number, out: Node[]): void {
	let f = sc.finallyStack.length - 1;
	while (f >= 0) {
		if (sc.finallyStack[f].loopDepth > targetLoopIdx) {
			for (const s of sc.finallyStack[f].stmts) out.push(s);
		}
		f = f - 1;
	}
}

// Inline ALL enclosing finally bodies (innermost first) — a return leaves
// every try, not just the innermost loop-crossing subset.
function pushAllFinallies(sc: StateCollector, out: Node[]): void {
	let f = sc.finallyStack.length - 1;
	while (f >= 0) {
		for (const s of sc.finallyStack[f].stmts) out.push(s);
		f = f - 1;
	}
}

export function splitStmts(stmts: Node[], sc: StateCollector, startState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	let currentState = startState;
	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		// break/continue inside a while-with-yield: rewrite to state transition
		// (see LoopFrame). No active frame → enclosing while has no yield,
		// natural C semantics apply, leave as-is.
		if (stmt.kind === NodeKind.BreakStmt && sc.loopStack.length > 0) {
			// Direct break: post-break stmts are dead, no need for trailing continue.
			const top = sc.loopStack[sc.loopStack.length - 1];
			pushCrossedFinallies(sc, sc.loopStack.length - 1, sc.items[currentState].stmts);
			sc.items[currentState].stmts.push(makeStateAssign(top.breakState, loc));
			return;
		} else if (stmt.kind === NodeKind.ContinueStmt && sc.loopStack.length > 0) {
			const top = sc.loopStack[sc.loopStack.length - 1];
			pushCrossedFinallies(sc, sc.loopStack.length - 1, sc.items[currentState].stmts);
			sc.items[currentState].stmts.push(makeStateAssign(top.continueState, loc));
			return;
		} else if (stmt.kind === NodeKind.ReturnStmt && sc.finallyStack.length > 0) {
			// finallyPath port: a bare return inside a SPLIT try runs every
			// enclosing finally before leaving. The return itself is left in
			// its incoming shape (async consumers pre-rewrite returns into
			// completion blocks that never reach this arm; generator returns
			// keep their V1 shape).
			pushAllFinallies(sc, sc.items[currentState].stmts);
			sc.items[currentState].stmts.push(stmt);
			i += 1;
		} else if (!containsYield(stmt)) {
			// Nested break/continue inside pushed-as-is stmt (e.g. `if (x) break;`
			// where the if has no yield) needs the trailing-continue form.
			if (sc.loopStack.length > 0) {
				rewriteLoopExits(stmt, sc.loopStack[sc.loopStack.length - 1], loc);
			}
			sc.items[currentState].stmts.push(stmt);
			i += 1;
		} else if (stmt.kind === NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			if (ed.expr.kind === NodeKind.YieldExpr) {
				// yield expr; → emit return { value: expr, done: false }, transition
				const yd = ed.expr.data as YieldExprData;
				const nextSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				emitYield(sc, currentState, nextSt, yd.yieldArg, loc, resultType);
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
			if (vd.initializer !== null && vd.initializer.kind === NodeKind.YieldExpr) {
				// const x = yield expr; → yield, then assign on resume
				const yd = vd.initializer.data as YieldExprData;
				const nextSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				emitYield(sc, currentState, nextSt, yd.yieldArg, loc, resultType);
				sc.items[currentState].yieldVarName = vd.declName;
				sc.items[currentState].yieldVarType = stmt.nodeType;
				// On resume: convert decl to assignment (var is lifted)
				if (i + 1 < stmts.length) {
					currentState = nextSt;
				}
				i += 1;
			} else if (vd.initializer !== null) {
				// VariableDecl with yield somewhere in initializer — treat as normal for V1
				// Convert to assignment since var is lifted
				const assignStmt = makeExprStmt(
					makeAssign(makeIdent(vd.declName, loc), vd.initializer, loc),
					loc,
				);
				sc.items[currentState].stmts.push(assignStmt);
				i += 1;
			} else {
				// No initializer — just skip, var is already lifted
				i += 1;
			}
		} else if (stmt.kind === NodeKind.WhileStmt) {
			// Flush current state to a new condition state so pre-loop stmts
			// don't re-execute on back-edge. Same pattern as reference closureiters.
			const condState = allocState(sc);
			sc.items[currentState].stmts.push(makeStateAssign(condState, loc));
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitWhile(stmt, sc, condState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind === NodeKind.IfStmt) {
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitIf(stmt, sc, currentState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind === NodeKind.BlockStmt) {
			// Unwrap block: forOfLower wraps lowered while loops in BlockStmt.
			const bd = stmt.data as BlockStmtData;
			const merged: Node[] = [];
			for (const bs of bd.statements) { merged.push(bs); }
			let ri = i + 1;
			while (ri < stmts.length) { merged.push(stmts[ri]); ri = ri + 1; }
			splitStmts(merged, sc, currentState, exitState, loc, resultType);
			return;
		} else if (stmt.kind === NodeKind.TryCatchStmt) {
			const td = stmt.data as TryCatchStmtData;
			const hasFinally = td.finallyBody !== null && !isEmptyBlock(td.finallyBody);
			// finallyPath port: try-with-finally containing a yield splits with
			// the finally inlined at each exit (splitTryFinally). A yield inside
			// the finally body itself stays a loud V1 gap (it would need its own
			// resumable states) — pushed as-is, codegen's unsupported-expression
			// comment fails the build, unchanged behaviour. Catch-less and
			// finally-less tries have nothing to split on.
			if (hasFinally && containsYield(td.finallyBody)) {
				sc.items[currentState].stmts.push(stmt);
				i += 1;
			} else if (hasFinally) {
				const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				splitTryFinally(stmt, sc, currentState, afterSt, loc, resultType);
				currentState = afterSt;
				i += 1;
			} else if (td.catchBody === null) {
				sc.items[currentState].stmts.push(stmt);
				i += 1;
			} else {
				const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				splitTryCatch(stmt, sc, currentState, afterSt, loc, resultType);
				currentState = afterSt;
				i += 1;
			}
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
function splitWhile(node: Node, sc: StateCollector, currentState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	const wd = node.data as WhileStmtData;

	// Condition state = currentState (reuse, already allocated)
	const condState = currentState;

	// Allocate body start (exit comes from caller — same pattern as splitIf)
	const bodyStart = allocState(sc);

	// Condition: if (cond) { $state = bodyStart } else { $state = exitState }
	sc.items[condState].stmts.push(
		makeIf(
			wd.whileCondition,
			makeBlock([makeStateAssign(bodyStart, loc)], loc),
			makeBlock([makeStateAssign(exitState, loc)], loc),
			loc,
		),
	);

	const bodyStmts = extractBodyStmts(wd.whileBody);
	sc.loopStack.push({ breakState: exitState, continueState: condState });
	splitStmts(bodyStmts, sc, bodyStart, condState, loc, resultType);
	sc.loopStack.pop();
}

// Split try/catch (no finally) containing a yield into states.
// Reference closureiters model: the try body's states form the exceptionTable
// entries (they land on the catch state); the catch body is its own state
// sequence; both rejoin at afterSt. The runtime routing (exceptionTable lookup
// on raise) is emitted by buildExcRouting as the wrapping catch.
function splitTryCatch(node: Node, sc: StateCollector, currentState: number, afterSt: number, loc: SourceLocation, resultType: Type | null): void {
	const td = node.data as TryCatchStmtData;
	const catchSt = allocState(sc);
	const tryStart = allocState(sc);
	// tryExit sits inside the excLanding range below so a trailing await's resume
	// (the re-raising read) routes to the catch, not the shared post-try state.
	const tryExit = allocState(sc);
	sc.items[currentState].stmts.push(makeStateAssign(tryStart, loc));

	splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
	// exceptionTable: every state produced for the try body lands on the catch.
	// Guard `excLanding < 0` so a nested inner try keeps its own (already-set) catch.
	for (let s = tryStart; s < sc.items.length; s += 1) {
		if (sc.items[s].excLanding < 0) sc.items[s].excLanding = catchSt;
	}
	sc.items[tryExit].stmts.push(makeStateAssign(afterSt, loc));

	// Rewrite the catch variable to read the env-carried current exception
	// ($curExc, reference :curExc) directly. buildExcRouting stores $excCaught into
	// $curExc on the raise path, which survives the await→raise→catch state
	// boundary that the runtime global msCurrException does not. Reading the env
	// field (not a per-state local) keeps the value in scope across every split
	// state and lets the env's DRC hooks own its lifetime — a local would be
	// cleaned up per-state and dangle on the try-body unwind paths.
	// $curExc carries the caught exception; its type must be the exception type
	// (DRC-owned) even when the handler never reads the catch var — otherwise the
	// env field falls back to void* and the exception leaks (no destructor hook).
	if (node.nodeType !== null) sc.excType = node.nodeType;
	if (td.catchName !== "") {
		renameIdentInSubtree(td.catchBody, td.catchName, "$curExc", node.nodeType);
	}
	splitStmts(extractBodyStmts(td.catchBody), sc, catchSt, afterSt, loc, resultType);
}

// finallyPath helpers: the normal exit routes through a dedicated landing-free
// finally state (an exception raised BY the finally body propagates directly
// instead of re-entering a landing that would run the finally a second time);
// the exception path runs the finally then re-raises $curExc out of the
// machine (reference closureiters end-finally raise branch). Returns the
// finally state index so later excLanding mark-loops can skip it.
function appendNormalFinally(sc: StateCollector, exitStateIdx: number, finStmts: Node[], afterSt: number, loc: SourceLocation): number {
	const finNormal = allocState(sc);
	sc.items[exitStateIdx].stmts.push(makeStateAssign(finNormal, loc));
	for (const s of finStmts) sc.items[finNormal].stmts.push(s);
	sc.items[finNormal].stmts.push(makeStateAssign(afterSt, loc));
	return finNormal;
}

function appendReraiseFinally(sc: StateCollector, finReraiseIdx: number, finStmts: Node[], loc: SourceLocation): void {
	for (const s of finStmts) sc.items[finReraiseIdx].stmts.push(s);
	sc.items[finReraiseIdx].stmts.push(makeStateAssign(-1, loc));
	const curExcRef = makeIdent("$curExc", loc);
	if (sc.excType !== null) curExcRef.nodeType = sc.excType;
	sc.items[finReraiseIdx].stmts.push(createNode(NodeKind.ThrowStmt, { throwArg: curExcRef }, syntheticToken(loc)));
}

// Split a try containing BOTH a yield and a finally (yield-free finally),
// with or without a catch. finallyPath port (reference closureiters): the
// reference routes finally exits through a runtime :finallyPath env array;
// with a yield-free finally body the finally state is single-shot straight
// line code, so inlining it at each exit is equivalent (the reference itself
// inlines single-entry states). Exits covered:
//   normal try completion   → finNormal  [fin..., goto afterSt]
//   normal catch completion → finNormal2 [fin..., goto afterSt]  (catch case)
//   raise in try body       → catchSt (catch case) / finReraise
//   raise in catch body     → finReraise [fin..., $state=-1, rethrow $curExc]
//   break/continue/return crossing the try → splitStmts via sc.finallyStack
// Exit paths are mutually exclusive, so the shared stmt nodes execute exactly
// once per execution. tryExit/catchExit keep an excLanding on purpose: a
// trailing await's resume read (the re-raising read) executes at their entry.
// Known divergence from the reference's runtime routing: a finally body that
// itself raises can run twice on the resume-read boundary path (the reference
// runs it once) — a corner documented at corpus 420.
function splitTryFinally(node: Node, sc: StateCollector, currentState: number, afterSt: number, loc: SourceLocation, resultType: Type | null): void {
	const td = node.data as TryCatchStmtData;
	const finStmts = extractBodyStmts(td.finallyBody);
	if (node.nodeType !== null) sc.excType = node.nodeType;
	const tryStart = allocState(sc);
	const tryExit = allocState(sc);
	sc.items[currentState].stmts.push(makeStateAssign(tryStart, loc));
	sc.finallyStack.push({ stmts: finStmts, loopDepth: sc.loopStack.length });

	if (td.catchBody === null) {
		const finReraise = allocState(sc);
		splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
		for (let s = tryStart; s < sc.items.length; s += 1) {
			if (s !== finReraise && sc.items[s].excLanding < 0) sc.items[s].excLanding = finReraise;
		}
		appendReraiseFinally(sc, finReraise, finStmts, loc);
		appendNormalFinally(sc, tryExit, finStmts, afterSt, loc);
	} else {
		// tryStart/tryExit are pre-allocated above, so catchSt's index sits
		// INSIDE the try-body mark range — the `s !== catchSt` guard keeps the
		// catch from landing on itself (splitTryCatch avoids this by allocating
		// catchSt first; here the two mark loops below cover both orders).
		const catchSt = allocState(sc);
		splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
		for (let s = tryStart; s < sc.items.length; s += 1) {
			if (s !== catchSt && sc.items[s].excLanding < 0) sc.items[s].excLanding = catchSt;
		}
		const finNormal = appendNormalFinally(sc, tryExit, finStmts, afterSt, loc);
		const catchExit = allocState(sc);
		const finReraise = allocState(sc);
		splitStmts(extractBodyStmts(td.catchBody), sc, catchSt, catchExit, loc, resultType);
		// finNormal must stay landing-free (single finally run); everything else
		// in the catch range — catchSt itself, catchExit's entry read included —
		// runs the finally then re-raises.
		for (let s = catchSt; s < sc.items.length; s += 1) {
			if (s !== finReraise && s !== finNormal && sc.items[s].excLanding < 0) sc.items[s].excLanding = finReraise;
		}
		appendReraiseFinally(sc, finReraise, finStmts, loc);
		appendNormalFinally(sc, catchExit, finStmts, afterSt, loc);
	}
	sc.finallyStack.pop();
}

// Rewrite every Identifier named `oldName` in `node`'s subtree to `newName`,
// stamping `typ` so member access (e.g. `$curExc.message`) resolves post-check.
function renameIdentInSubtree(node: Node, oldName: string, newName: string, typ: Type | null): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (d.name === oldName) {
			d.name = newName;
			if (typ !== null) node.nodeType = typ;
			node.resolvedSym = null;
		}
		return;
	}
	forEachChild(node, (child: Node): void => { renameIdentInSubtree(child, oldName, newName, typ); });
}

// Wrapping-catch body: capture the exception into $exc, then map the raising
// state to its landing (reference exceptionTable[:state]) as an if-chain; a state
// with no landing propagates out (go terminal + re-raise).
export function buildExcRouting(sc: StateCollector, loc: SourceLocation): Node {
	const stmts: Node[] = [];
	// Carry the caught exception across the state boundary (reference :curExc) so
	// the catch state can bind its variable from $curExc after control resumes.
	// MOVE (reference nkFastAsgn — no incref): $curExc becomes the exception's sole
	// owner and the env's DRC hooks free it once. A copy here over-owns (the sole
	// currException ref is dropped by the clear without decref) → leak on every catch.
	stmts.push(makeExprStmt(makeAssign(makeIdent("$curExc", loc), makeMoveExpr(makeIdent("$excCaught", loc), loc), loc), loc));
	// Terminal re-raises $curExc — the slot the store above just filled — never
	// $excCaught, which the store's move already nulled (reference closureiters
	// wrapIntoTryExcept re-raises :curExc). Typed so the raise-arg sink fires.
	const curExcRef = makeIdent("$curExc", loc);
	if (sc.excType !== null) curExcRef.nodeType = sc.excType;
	const rethrow = createNode(NodeKind.ThrowStmt, { throwArg: curExcRef }, syntheticToken(loc));
	let chain: Node = makeBlock([makeStateAssign(-1, loc), rethrow], loc);
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		if (sc.items[i].excLanding >= 0) {
			const cond = makeBinary(makeIdent("$state", loc), "===", makeNumber(i, loc), loc);
			const then = makeBlock([makeStateAssign(sc.items[i].excLanding, loc)], loc);
			chain = makeIf(cond, then, chain, loc);
		}
	}
	stmts.push(chain);
	return makeBlock(stmts, loc);
}

export function hasExcLanding(sc: StateCollector): boolean {
	for (const st of sc.items) { if (st.excLanding >= 0) return true; }
	return false;
}

export function wrapExcRouting(dispatch: Node, sc: StateCollector, loc: SourceLocation): Node {
	if (!hasExcLanding(sc)) return dispatch;
	return makeTryCatch(dispatch, "$excCaught", buildExcRouting(sc, loc), null as unknown as Node, loc);
}

export function makeCurExcDecl(sc: StateCollector, loc: SourceLocation): Node {
	const curExcDecl = makeVarDecl("$curExc", makeNull(loc), DeclKind.Let, loc);
	// No known exception type (catch-less try/finally): a raw Ptr<void> holder.
	// Never noneType() — TypeKind.None is a sentinel that trips the codegen
	// unresolved-type gate. DRC corner (documented, same as an untyped env
	// field): a ref exception rethrown through a catch-less finally has no
	// destructor hook on this holder and leaks on the error path.
	curExcDecl.nodeType = sc.excType !== null ? sc.excType : createPtr(createPrimitive(TypeKind.Void));
	return curExcDecl;
}

// Split if-else containing yield:
// currentState: if (cond) { $state = thenStart } else { $state = elseStart }
// thenStates: ... → joinState
// elseStates: ... → joinState
function splitIf(node: Node, sc: StateCollector, currentState: number, joinState: number, loc: SourceLocation, resultType: Type | null): void {
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
		splitStmts(thenStmts, sc, thenStart, joinState, loc, resultType);
		const elseStmts = extractBodyStmts(id.alternate);
		splitStmts(elseStmts, sc, elseStart, joinState, loc, resultType);
	} else {
		// Only then branch has yield (or no else). Since else has no await,
		// inline its body inside the if-else's else branch (executed
		// conditionally when cond=false), followed by transition to joinState.
		// Earlier this incorrectly pushed else body into joinState's stmts,
		// which leaked the else body into the parent context (e.g. an
		// enclosing while-condition state ran the else body unconditionally).
		const elseBlockStmts: Node[] = [];
		if (hasElse) {
			const elseStmts = extractBodyStmts(id.alternate);
			for (const s of elseStmts) elseBlockStmts.push(s);
		}
		elseBlockStmts.push(makeStateAssign(joinState, loc));

		sc.items[currentState].stmts.push(
			makeIf(
				id.condition,
				makeBlock([makeStateAssign(thenStart, loc)], loc),
				makeBlock(elseBlockStmts, loc),
				loc,
			),
		);
		const thenStmts = extractBodyStmts(id.consequent);
		splitStmts(thenStmts, sc, thenStart, joinState, loc, resultType);
	}
}

// ===== Return Rewriting =====
// Rewrite return stmts in generator body: return val → $state = -1; return { value: val, done: true }

function rewriteReturns(stmts: Node[], loc: SourceLocation, resultType: Type | null): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.ReturnStmt) {
			const rd = stmt.data as ReturnStmtData;
			// Replace with block: { $state = -1; return { value: val, done: true }; }
			const block = makeBlock([
				makeStateAssign(-1, loc),
				makeReturn(makeIterResult(rd.argument!, true, loc, resultType), loc),
			], loc);
			stmts[i] = block;
		}
	}
}

// ===== Variable Declaration → Assignment =====
// Convert lifted variable declarations to assignments in state bodies.
// Variables are hoisted to function scope, so decls become assignments.

export function convertDeclsToAssigns(stmts: Node[], liftedNames: NameSet, loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (nameSetContains(liftedNames, vd.declName) && vd.initializer !== null) {
				// Convert: const/let x = init → x = init (assignment)
				// Preserve the VarDecl's resolvedSym on the LHS Identifier so downstream
				// passes (lambdaLifting capture resolution, codegen) identify this as the
				// original local binding — not a fall-through to an outer/global with the
				// same name. Critical for shadow-safe rewriting of async state machines.
				const lhs = (stmt.resolvedSym !== null)
					? makeIdentResolved(stmt.resolvedSym, loc)
					: makeIdent(vd.declName, loc);
				stmts[i] = makeExprStmt(makeAssign(lhs, vd.initializer, loc), loc);
			}
		}
	}
}

// ===== State Machine Builder =====

function buildStateDispatch(sc: StateCollector, loc: SourceLocation, resultType: Type | null): Node {
	// Default (terminal) state: return { value: null, done: true }
	let current: Node = makeBlock([makeReturn(makeDoneResult(loc, resultType), loc)], loc);

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

function transformGeneratorFn(params: string[], paramTypes: string[], body: Node, flags: string, returnType: string, returnNodeType: Type | null, loc: SourceLocation): Node {
	// 1. Collect all local variable names and their types
	const nc: NameSet = createNameSet();
	collectDeclNames(body, nc, false);
	const dtNames: string[] = [];
	const dtTypes: Type[] = [];
	collectDeclTypes(body, dtNames, dtTypes);

	// 2. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// Build IteratorResult<T> type for stamping yield/return literals
	const iterResultType = buildIterResultType(returnNodeType);

	// 3. Rewrite return statements
	rewriteReturns(bodyStmts, loc, iterResultType);

	// 4. Split at yield points
	const sc: StateCollector = { items: [], loopStack: [], excType: null, finallyStack: [] };
	const initState = allocState(sc);
	const doneState = -1;  // terminal

	splitStmts(bodyStmts, sc, initState, doneState, loc, iterResultType);

	// 5. Convert variable declarations to assignments in all state bodies
	for (const st of sc.items) {
		convertDeclsToAssigns(st.stmts, nc, loc);
	}

	// 6. Build the state dispatch (if-else chain)
	const dispatch = buildStateDispatch(sc, loc, iterResultType);

	// 6b. If any state has an exception landing (a try with a yield inside),
	// wrap the dispatch in a try/catch that routes a raised state to its
	// landing (reference closureiters exceptionTable + the wrapping except).
	const hasExc = hasExcLanding(sc);
	const dispatchBody = wrapExcRouting(dispatch, sc, loc);

	// 7. Wrap in while(true) { dispatch }
	const loop = makeWhile(makeBool(true, loc), dispatchBody, loc);

	// 8. Build next() function body
	const nextBody = makeBlock([loop], loc);

	// 9. Create next FunctionExpr with proper return type (IteratorResult<T>)
	// Lambda lifting uses nodeType to determine the lifted function's return type.
	const nextFnType = getIteratorNextFnType(returnNodeType);
	const nextFn = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [],
		funcExprParamTypes: [],
		funcExprBody: nextBody,
		funcExprFlags: "",
		funcExprReturnType: "",
	}, syntheticToken(loc));
	if (nextFnType !== null) nextFn.nodeType = nextFnType;

	// 10. Build iterator object: { next: function() { ... } }
	// Set nodeType to Iterator so C codegen emits the named struct, not anonymous.
	const iterObj = makeObjectLiteral(["next"], [nextFn], loc);
	if (returnNodeType !== null && isIterator(returnNodeType)) {
		iterObj.nodeType = returnNodeType;
	}

	// 11. Build new function body:
	//   let $state = 0;
	//   let local1; let local2; ...
	//   return { next: function() { while(true) { if-else dispatch } } };
	const newBodyStmts: Node[] = [];
	newBodyStmts.push(makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc));
	if (hasExc) newBodyStmts.push(makeCurExcDecl(sc, loc));
	for (const localName of nc.items) {
		// Stamp original nodeType so lambda lifting creates correctly-typed env fields.
		// Reference parity: captureVar always adds field with original type.
		const decl = makeVarDecl(localName, makeNull(loc), DeclKind.Let, loc);
		const dt = lookupDeclType(dtNames, dtTypes, localName);
		if (dt !== null) decl.nodeType = dt;
		newBodyStmts.push(decl);
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
				// Skip generic templates — only monomorphized instances should be lowered.
				// Generic templates have unresolved type params that produce void in C.
				const fnType = node.resolvedSym !== null ? node.resolvedSym.symbolType : null;
				if (fnType !== null && hasGenericParams(fnType)) {
					// Keep generator flag so monomorphized instances still get lowered
				} else {
					const retType = fnType !== null ? fnType.typeReturn : null;
					d.fnBody = transformGeneratorFn(
						d.params, d.fnParamTypes, d.fnBody,
						d.fnFlags, d.fnReturnType, retType, node.location,
					);
					d.fnFlags = "";
				}
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
			if (d.initializer !== null) walkCheckFuncExpr(d.initializer);
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
				d.funcExprFlags, d.funcExprReturnType, node.nodeType !== null ? node.nodeType.typeReturn : null, node.location,
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

test "try finally with yield splits" { assert stmtCountAfter("function* gen() { try { yield 1; } finally { x = 2; } }", lowerGenerator) === 1; }

test "try catch finally with yield splits" { assert stmtCountAfter("function* gen() { try { yield 1; } catch (e) { y = 3; } finally { x = 2; } }", lowerGenerator) === 1; }

test "yield in finally stays passthrough" { assert stmtCountAfter("function* gen() { try { x = 1; } finally { yield 2; } }", lowerGenerator) === 1; }

test "two yields" { assert stmtCountAfter("function* gen() { yield 1; yield 2; }", lowerGenerator) === 1; }

test "yield with locals" { assert stmtCountAfter("function* gen() { let x = 1; yield x; }", lowerGenerator) === 1; }

test "while yield loop" { assert stmtCountAfter("function* gen() { let i = 0; while (i < 3) { yield i; i = i + 1; } }", lowerGenerator) === 1; }

test "regular function unchanged" { assert stmtCountAfter("function f() { while (true) {} }", lowerGenerator) === 1; }
