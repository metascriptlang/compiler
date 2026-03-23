// Statement Checker — Pass 3 statement validation and control flow
// Expression checking extracted to checkExprPass.ms. Uses checkerCallbacks for mutual recursion.

import { Node, NodeKind, NodeFlag, DeclKind, SourceLocation, makeLoc, createNodeAt, ExprStmtData, ThrowStmtData, DeferStmtData, DecoratedDeclData, IdentifierData, BinaryExprData, MemberExprData, VariableDeclData, FunctionDeclData, ClassDeclData, MethodDeclData, ConstructorDeclData, ExportDeclData, ImportDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, BlockStmtData, ReturnStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, MatchStmtData, MatchCaseData, DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, ProgramData, MacroInvocationData, StringLiteralData, CallExprData, TestDeclData, AssertStmtData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { unknownType, nullType, stringType, charType, numberType, float64Type, voidType, createFunction, createUnion, isMaybeType, unwrapMaybeType, isNarrowingIntConv, typeNameOf, isPromise, getPromiseInner, isResult, getResultOkType, getResultErrType, isDiscriminatedUnion, getDiscriminantName, findVariantByDiscriminant } from "./types";
import { ScopeKind, defineSymbol, lookupSymbol, lookupLocal, makeSymbol, openScope, closeScope, setFlag, hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, CancelCtx, createContext, createContextWithCache, createModuleContext, createModuleContextWithCache, addError, addFatalError, addWarning, hasErrors, hasFatalErrors, errorCount, createExtensionRegistry, registerExtension, ExtensionMethod, ExportRegistry, ExportedSymInfo, registerModuleExports, buildExportInfo, isCancelled, sgRecordSym, sgSortRecords, isInAsyncPromiseResult } from "./context";
import { IdentCache, createIdentCache } from "./idents";
import { Module, ModuleGraph } from "../module/graph";
import { collectTopLevel, defineOrError } from "./collectPass";
import { getIdentId } from "./idents";
import { readFile } from "std/process";
import { globalImports } from "./prelude";
import { isAssignable } from "./compat";
import { resolveDeclarations, resolveAnnotation, resolveTypeExpr, resolveTypeExprs, ensureShaped } from "./resolvePass";
import { inferOwnership } from "./ownershipInference";
import { analyzeParamMutations } from "./paramMutationAnalysis";
import { validateTypedAST } from "./validate";
import { getModuleDir, appendFlag, prependFlag, concatFlag } from "../utils/string";
import { checkExpr, checkEnumExhaustiveness, checkDuplicatePatterns, fitNode } from "./checkExprPass";
import { registerCheckStmt, registerCheckFunctionBody } from "./checkerCallbacks";
import "./instantiate"; // side-effect: registers instantiateGenericFunction callback
import { parseSource } from "../parser/statements/validation";
import {
	InitTracker, BreakState, createInitTracker,
	markInitialized, isInitialized, saveInitState, restoreInitState,
	breaksBlock, mergeInitBranches, collectNewInits, isAlwaysTrue, impliesNotNull, varDecl,
} from "./initTracker";

// Extract directory from module path (e.g. "src/foo/bar.ms" → "src/foo")
// Brief type description for error messages
function formatTypeBrief(t: Type): string {
	if (t === null) return "unknown";
	if (isResult(t)) {
		const okName = getResultOkType(t) !== null ? typeNameOf(getResultOkType(t)) : "?";
		const errName = getResultErrType(t) !== null ? typeNameOf(getResultErrType(t)) : "?";
		return "Result<" + (okName !== "" ? okName : "void") + ", " + (errName !== "" ? errName : "?") + ">";
	}
	const name = typeNameOf(t);
	return name !== "" ? name : t.kind.toString();
}

// ===== Statement Checker =====

export function checkStmt(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.VariableDecl => checkVariableDecl(ctx, node),
		NodeKind.FunctionDecl => checkFunctionDecl(ctx, node),
		NodeKind.ClassDecl => checkClassDecl(ctx, node),
		NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.EnumDecl | NodeKind.TypeAliasDecl |
		NodeKind.ExternDecl | NodeKind.MacroDecl | NodeKind.ImportDecl => {},
		NodeKind.ExportDecl => checkExportDecl(ctx, node),
		NodeKind.IfStmt => checkIfStmt(ctx, node),
		NodeKind.WhileStmt => checkWhileStmt(ctx, node),
		NodeKind.ForStmt => checkForStmt(ctx, node),
		NodeKind.ForOfStmt => checkForOfStmt(ctx, node),
		NodeKind.ForInStmt => checkForInStmt(ctx, node),
		NodeKind.DoWhileStmt => checkDoWhileStmt(ctx, node),
		NodeKind.BlockStmt => checkBlock(ctx, node),
		NodeKind.ReturnStmt => checkReturnStmt(ctx, node),
		NodeKind.BreakStmt => { if (!ctx.inLoop) { addError(ctx, "break outside of loop", node.location.line, node.location.column); } },
		NodeKind.ContinueStmt => { if (!ctx.inLoop) { addError(ctx, "continue outside of loop", node.location.line, node.location.column); } },
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			checkExpr(ctx, d.expr, null);
			// Warn: spawn result not awaited — borrowed captures may dangle
			// Suppress inside loops: fire-and-forget spawn for worker threads is a valid pattern
			if (d.expr.kind === NodeKind.CallExpr && d.expr.resolvedSym !== null
				&& d.expr.resolvedSym.builtinKind === "PromiseSpawn" && !ctx.inLoop) {
				addWarning(ctx, "spawn result not awaited — borrowed captures may outlive scope", d.expr.location.line, d.expr.location.column);
			}
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			checkExpr(ctx, d.throwArg, null);
			// V1: throw forbidden in async functions returning Promise<Result<T,E>>
			if (isInAsyncPromiseResult(ctx)) {
				addError(ctx, "throw is forbidden in async function returning Promise<Result<T,E>> — use Result.err() instead", node.location.line, node.location.column);
			}
		},
		NodeKind.TryCatchStmt => checkTryCatch(ctx, node),
		NodeKind.SwitchStmt => checkSwitchStmt(ctx, node),
		NodeKind.MatchStmt => checkMatchStmt(ctx, node),
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			checkExpr(ctx, d.deferExpr, null);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			if (d.decoratedNode !== null) checkStmt(ctx, d.decoratedNode);
		},
		NodeKind.DestructuringDecl => checkDestructuringDecl(ctx, node),
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			// Test blocks compile to functions — allow return statements inside
			const savedFunction = ctx.currentFunction;
			const savedInTest = ctx.inTestBlock;
			ctx.currentFunction = makeSymbol("__test__", SymbolKind.Function, unknownType(), false);
			ctx.inTestBlock = true;
			checkBlock(ctx, d.testBody);
			ctx.inTestBlock = savedInTest;
			ctx.currentFunction = savedFunction;
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			if (!ctx.inTestBlock) {
				addFatalError(ctx, "'assert' can only be used inside test blocks", node.location.line, node.location.column);
			}
			checkExpr(ctx, d.assertExpr, null);
		},
		_ => {},
	};
}

// ===== Statement Helpers =====

function checkVariableDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	// Resolve declared type FIRST so it can flow as expectedType into initializer (Implementation parity)
	let declType: Type = null;
	if (d.declType !== "") {
		const typeLoc = node.typeExpr !== null ? node.typeExpr.location : d.nameLocation;
		declType = resolveAnnotation(d.declType, ctx, typeLoc.line, typeLoc.column);
		resolveTypeExpr(node.typeExpr, ctx);
	}
	const initType = checkExpr(ctx, d.initializer, declType);
	// Parity: standard reference node fitting — insert HiddenStdConv for narrowing integer conversions
	if (declType !== null && d.initializer !== null) {
		d.initializer = fitNode(ctx, d.initializer, declType, initType);
	}
	// Prefer explicit type annotation over inferred type
	let varType = initType;
	if (declType !== null) {
		varType = declType;
	}
	node.nodeType = varType;
	// If already collected in pass 1 (e.g. export const), update type
	const existing = lookupLocal(ctx.table, d.declName);
	if (existing !== null) {
		existing.symbolType = varType;
		if (d.declKind !== DeclKind.Const) {
			setFlag(existing, SymbolFlag.Mutable);
		}
		node.resolvedSym = existing;
		sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.declName.length, existing, varType, SymbolKind.Variable, d.declName, "", true);
	} else {
		const newSym = makeSymbol(d.declName, SymbolKind.Variable, varType, d.declKind !== DeclKind.Const);
		defineOrError(ctx, newSym, node);
		node.resolvedSym = newSym;
		sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.declName.length, newSym, varType, SymbolKind.Variable, d.declName, "", true);
	}
	// Ref parity: varDecl — record declaration block for nfFirstWrite logic
	varDecl(ctx.initTracker, d.declName);
	// Ref parity: initVar if initializer present (sempass2 lines 1317-1318)
	// Any initializer counts — even `null as unknown as T` (initialized, just null-valued)
	if (d.initializer !== null) {
		node.flags = node.flags | NodeFlag.FirstWrite;
		markInitialized(ctx.initTracker, d.declName);
	}
	// `let x;` with no initializer → NOT marked → will warn on use
}

function checkFunctionDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = lookupSymbol(ctx.table, d.fnName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Demand-driven: ensure signature is shaped before checking body
	ensureShaped(sym, ctx);
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.fnName.length, sym, sym.symbolType, SymbolKind.Function, d.fnName, "", true);

	// Multi-pass parity: avoid re-checking body if already done
	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	const fnType = sym.symbolType;
	node.nodeType = fnType;

	// Mark async functions for return type unwrapping
	if (d.fnFlags === "async" || d.fnFlags === "async_generator" || (d.fnFlags !== "" && d.fnFlags.indexOf("async") >= 0)) {
		setFlag(sym, SymbolFlag.Async);
	}

	// Reference parity (semProcAux): generic function bodies are NOT checked at declaration time.
	// They're stored as raw AST and only checked when instantiated with concrete types
	// (via instantiateGenericFunction → checkFunctionBody). This prevents creating
	// bad instantiations (push__unknown) from unresolved GenericParam types.
	const isGeneric = d.fnFlags !== "" && d.fnFlags.indexOf("gen:") >= 0;
	if (isGeneric) {
		sym.state = SymbolState.Checked;
		return;
	}

	// Save/restore inferredReturn for nested functions
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = fnType.typeReturn;

	checkFunctionBody(ctx, sym, d.params, d.fnBody, node.paramLocations);

	// If return type was unknown (no annotation), use inferred type
	if (sym.symbolType.kind === TypeKind.Function
		&& sym.symbolType.typeReturn !== null
		&& sym.symbolType.typeReturn.kind === TypeKind.Unknown
		&& ctx.inferredReturn.kind !== TypeKind.Unknown) {
		sym.symbolType.typeReturn = ctx.inferredReturn;
	}

	// @pure effect check: warn on impure calls inside pure functions
	if (sym.builtinKind === "pure" && d.fnBody !== null) {
		checkPurityViolations(ctx, d.fnBody);
	}

	ctx.inferredReturn = savedReturn;
	sym.state = SymbolState.Checked;
}

function checkClassDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Demand-driven: ensure class fields/methods are shaped
	ensureShaped(sym, ctx);
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.className.length, sym, sym.symbolType, SymbolKind.Class, d.className, "", true);

	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	openScope(ctx.table, ScopeKind.Class);
	for (const member of d.classBody) {
		checkClassMember(ctx, member, d.className, sym.symbolType);
	}
	closeScope(ctx.table);

	sym.state = SymbolState.Checked;
}

function checkClassMember(ctx: CheckerContext, node: Node, className: string, classType: Type): void {
	// DecoratedDecl wrapping a class member — unwrap and check the inner node
	if (node === null) return;
	if (node.kind === NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		if (dd.decoratedNode !== null) checkClassMember(ctx, dd.decoratedNode, className, classType);
		return;
	}
	match (node.kind) {
		NodeKind.PropertyDecl => {},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			const methodSym = node.resolvedSym;
			const sym = methodSym !== null ? methodSym : makeSymbol(d.methodName, SymbolKind.Method, unknownType(), false);
			sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.methodName.length, sym, sym.symbolType, SymbolKind.Method, d.methodName, className, true);
			checkFunctionBody(ctx, sym, d.methodParams, d.methodBody, node.paramLocations);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			// Record constructor DEF for symbol graph
			const ctorSym = node.resolvedSym;
			if (ctorSym !== null) {
				sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + 11, ctorSym, ctorSym.symbolType, SymbolKind.Method, "constructor", className, true);
			}
			// Constructor allocates `this` — prepend to params for checking so this.* resolves,
			// but don't modify AST (codegen handles `this` as a local, not a param).
			const ctorParams: string[] = ["this"];
			for (let cpi = 0; cpi < d.ctorParams.length; cpi += 1) {
				ctorParams.push(d.ctorParams[cpi]);
			}
			// Build constructor type with `this` at index 0
			const ctorType = node.nodeType;
			const ctorChildren: Type[] = [classType];
			if (ctorType !== null && ctorType.typeChildren !== null) {
				for (let cpi = 0; cpi < ctorType.typeChildren.length; cpi += 1) {
					ctorChildren.push(ctorType.typeChildren[cpi]);
				}
			}
			const ctorFnType = createFunction(ctorChildren, ctorParams, voidType());
			// Prepend null location for synthetic "this" param
			const ctorLocs: SourceLocation[] = [null as unknown as SourceLocation];
			if (node.paramLocations !== null) {
				for (const loc of node.paramLocations) { ctorLocs.push(loc); }
			}
			checkFunctionBody(ctx, makeSymbol("constructor", SymbolKind.Method, ctorFnType, false), ctorParams, d.ctorBody, ctorLocs);
		},
		_ => {},
	};
}

function checkExportDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExportDeclData;
	if (d.exportedDecl.kind === NodeKind.VariableDecl) {
		checkVariableDecl(ctx, d.exportedDecl);
		return;
	}
	checkStmt(ctx, d.exportedDecl);
}

// ===== Null Narrowing (Fact-Based Model) =====
//
// Reference-aligned design: a Node[] knowledge base tracks known conditions.
// addFact decomposes && into separate facts. addFactNeg negates conditions.
// impliesNotNull queries the fact list. Save/restore via array length truncation.
// sym.symbolType mutation still applies narrowing (single-pass checker requirement).

function saveFacts(ctx: CheckerContext): number {
	return ctx.narrowFacts.length;
}

function restoreFacts(ctx: CheckerContext, snapshot: number): void {
	ctx.narrowFacts.length = snapshot;
}

// Decompose && into separate facts (both sides true). Other conditions pushed as-is.
function addFact(ctx: CheckerContext, condition: Node): void {
	if (condition.kind === NodeKind.BinaryExpr) {
		const d = condition.data as BinaryExprData;
		if (d.operator === "&&") {
			addFact(ctx, d.left);
			addFact(ctx, d.right);
			return;
		}
	}
	ctx.narrowFacts.push(condition);
}

function negateOp(op: string): string {
	if (op === "===") return "!==";
	if (op === "!==") return "===";
	if (op === "==") return "!=";
	if (op === "!=") return "==";
	return op;
}

// Negate and add. NOT(a||b) = !a && !b (decompose). NOT(a&&b) = !a || !b (opaque).
// Simple comparisons: flip operator. Fallback: push as opaque (impliesNotNull returns unknown).
function addFactNeg(ctx: CheckerContext, condition: Node): void {
	if (condition.kind === NodeKind.BinaryExpr) {
		const d = condition.data as BinaryExprData;
		// NOT(a || b) = !a && !b — CAN decompose
		if (d.operator === "||") {
			addFactNeg(ctx, d.left);
			addFactNeg(ctx, d.right);
			return;
		}
		// Simple comparisons: flip operator
		if (d.operator === "!==" || d.operator === "===" ||
			d.operator === "!=" || d.operator === "==") {
			const flipped = negateOp(d.operator);
			const neg = createNodeAt(NodeKind.BinaryExpr,
				{ operator: flipped, left: d.left, right: d.right }, condition.location);
			ctx.narrowFacts.push(neg);
			return;
		}
		// NOT(a && b) = !a || !b — CANNOT decompose, push as opaque
	}
	// Fallback: opaque fact (impliesNotNull won't match → returns unknown → no narrowing)
	ctx.narrowFacts.push(condition);
}

// impliesNotNull is now imported from initTracker.ms (shared with checkExprPass.ms)

// Extract variable names involved in null comparisons from a condition
function collectNullVars(node: Node, dest: string[]): void {
	if (node.kind !== NodeKind.BinaryExpr) return;
	const d = node.data as BinaryExprData;
	if (d.operator === "&&" || d.operator === "||") {
		collectNullVars(d.left, dest);
		collectNullVars(d.right, dest);
		return;
	}
	if (d.operator === "!==" || d.operator === "===") {
		if (d.left.kind === NodeKind.Identifier && d.right.kind === NodeKind.NullLiteral) {
			dest.push((d.left.data as IdentifierData).name);
		} else if (d.right.kind === NodeKind.Identifier && d.left.kind === NodeKind.NullLiteral) {
			dest.push((d.right.data as IdentifierData).name);
		}
	}
}

function extractNullCheckedVars(condition: Node): string[] {
	const result: string[] = [];
	collectNullVars(condition, result);
	return result;
}

// Apply narrowing to symbols based on current facts. Returns arrays for later restore.
// Deduplicates by symbol identity — prevents double-narrow corruption on (x !== null && x !== null).
function applyNarrowing(ctx: CheckerContext, vars: string[], narrowedSyms: Symbol[], savedTypes: Type[]): void {
	let i = 0;
	while (i < vars.length) {
		const sym = lookupSymbol(ctx.table, vars[i]);
		if (sym !== null && sym.symbolType !== null && sym.symbolType.kind !== TypeKind.Unknown) {
			// Skip if already narrowed in this batch
			let already = false;
			let k = 0;
			while (k < narrowedSyms.length) {
				if (narrowedSyms[k] === sym) { already = true; }
				k = k + 1;
			}
			if (already) { i = i + 1; continue; }
			const verdict = impliesNotNull(ctx.narrowFacts, vars[i]);
			if (verdict === 1) {
				savedTypes.push(sym.symbolType);
				narrowedSyms.push(sym);
				sym.symbolType = removeNullFromType(sym.symbolType);
			} else if (verdict === -1) {
				savedTypes.push(sym.symbolType);
				narrowedSyms.push(sym);
				sym.symbolType = nullType();
			}
		}
		i = i + 1;
	}
}

// Restore narrowed symbols to their original types
function restoreNarrowing(narrowedSyms: Symbol[], savedTypes: Type[]): void {
	let i = 0;
	while (i < narrowedSyms.length) {
		narrowedSyms[i].symbolType = savedTypes[i];
		i = i + 1;
	}
}

// Remove Null from a type (for narrowing after null checks)
function removeNullFromType(t: Type): Type {
	// Maybe<T> → T (Reference: Maybe/Option extraction)
	if (isMaybeType(t)) return unwrapMaybeType(t);
	if (t.kind === TypeKind.Union) {
		const nonNull: Type[] = [];
		for (const member of t.typeChildren) {
			if (member.kind !== TypeKind.Null) nonNull.push(member);
		}
		if (nonNull.length === 1) return nonNull[0];
		if (nonNull.length > 0) return createUnion(nonNull);
		return t;
	}
	if (t.kind === TypeKind.Null) return unknownType();
	return t;
}

// ===== Effect System (@pure) =====
// Walk function body looking for impure operations: calls to non-pure functions.

function checkPurityViolations(ctx: CheckerContext, body: Node): void {
	if (body === null) return;
	if (body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		let i = 0;
		while (i < bd.statements.length) {
			checkPurityViolations(ctx, bd.statements[i]);
			i = i + 1;
		}
		return;
	}
	if (body.kind === NodeKind.ExprStmt) {
		const ed = body.data as ExprStmtData;
		checkPurityViolations(ctx, ed.expr);
		return;
	}
	if (body.kind === NodeKind.ReturnStmt) {
		const rd = body.data as ReturnStmtData;
		if (rd.argument !== null) checkPurityViolations(ctx, rd.argument);
		return;
	}
	if (body.kind === NodeKind.IfStmt) {
		const id = body.data as IfStmtData;
		checkPurityViolations(ctx, id.condition);
		checkPurityViolations(ctx, id.consequent);
		if (id.alternate !== null) checkPurityViolations(ctx, id.alternate);
		return;
	}
	if (body.kind === NodeKind.VariableDecl) {
		const vd = body.data as VariableDeclData;
		if (vd.initializer !== null) checkPurityViolations(ctx, vd.initializer);
		return;
	}
	if (body.kind === NodeKind.CallExpr) {
		const cd = body.data as CallExprData;
		// Check if callee is a known pure function
		if (cd.callee.kind === NodeKind.Identifier) {
			const callId = cd.callee.data as IdentifierData;
			const calleeSym = lookupSymbol(ctx.table, callId.name);
			if (calleeSym !== null && calleeSym.builtinKind !== "pure") {
				addError(ctx, "@pure function calls impure function '" + callId.name + "'", body.location.line, body.location.column);
			}
		} else if (cd.callee.kind === NodeKind.MemberExpr) {
			// member calls (e.g. console.log) are impure by default
			const me = cd.callee.data as MemberExprData;
			addError(ctx, "@pure function calls impure method '" + me.property + "'", body.location.line, body.location.column);
		}
		// Also check arguments for nested impure calls
		let j = 0;
		while (j < cd.arguments.length) {
			checkPurityViolations(ctx, cd.arguments[j]);
			j = j + 1;
		}
		return;
	}
	if (body.kind === NodeKind.BinaryExpr) {
		const bd = body.data as BinaryExprData;
		checkPurityViolations(ctx, bd.left);
		checkPurityViolations(ctx, bd.right);
		return;
	}
}

// Check if a block/statement always exits (return, throw, break, continue, unreachable)
function isDefiniteExit(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ReturnStmt) return true;
	if (node.kind === NodeKind.ThrowStmt) return true;
	if (node.kind === NodeKind.BreakStmt) return true;
	if (node.kind === NodeKind.ContinueStmt) return true;
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		if (bd.statements.length === 0) return false;
		return isDefiniteExit(bd.statements[bd.statements.length - 1]);
	}
	return false;
}

// Check a branch body under narrowed facts. Saves/restores facts and symbol types.
function checkNarrowedBranch(ctx: CheckerContext, vars: string[], body: Node, addFacts: (ctx: CheckerContext, cond: Node) => void, condition: Node): void {
	const snap = saveFacts(ctx);
	addFacts(ctx, condition);
	const narrowedSyms: Symbol[] = [];
	const savedTypes: Type[] = [];
	applyNarrowing(ctx, vars, narrowedSyms, savedTypes);
	checkStmt(ctx, body);
	restoreNarrowing(narrowedSyms, savedTypes);
	restoreFacts(ctx, snap);
}

function checkIfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as IfStmtData;
	checkExpr(ctx, d.condition, null);
	const vars = extractNullCheckedVars(d.condition);

	// Ref parity: trackIf (sempass2 lines 847-889) — count table + exhaustiveness
	const oldState = saveInitState(ctx.initTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];

	// Track consequent
	checkNarrowedBranch(ctx, vars, d.consequent, addFact, d.condition);
	branchInits.push(collectNewInits(ctx.initTracker, oldState));
	branchBreaks.push(breaksBlock(d.consequent));

	// Track alternate (if present)
	const hasElse = d.alternate !== null && d.alternate.kind !== NodeKind.NullLiteral;
	if (hasElse) {
		restoreInitState(ctx.initTracker, oldState);
		checkNarrowedBranch(ctx, vars, d.alternate, addFactNeg, d.condition);
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(d.alternate));
	}

	// Ref parity: merge with exhaustiveness check
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, hasElse);
}

// ===== Loop Statements =====

function checkWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as WhileStmtData;
	checkExpr(ctx, d.whileCondition, null);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	// Ref parity (sempass2 lines 1346-1360): while(true) propagates, others conservative
	if (isAlwaysTrue(d.whileCondition)) {
		const saved = enterLoopScope(ctx);
		checkStmt(ctx, d.whileBody);
		exitLoopScope(ctx, saved);
	} else {
		const oldState = saveInitState(ctx.initTracker);
		const saved = enterLoopScope(ctx);
		checkStmt(ctx, d.whileBody);
		exitLoopScope(ctx, saved);
		restoreInitState(ctx.initTracker, oldState);
	}
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
}

function checkForStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForStmtData;
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.forInit);
	checkExpr(ctx, d.forCondition, null);
	// Ref parity: for loops — conservative, loop may not execute
	const oldState = saveInitState(ctx.initTracker);
	checkExpr(ctx, d.forUpdate, null);
	checkStmt(ctx, d.forBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldState);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
}

function checkForOfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForOfStmtData;
	checkExpr(ctx, d.forOfIterable, null);
	// Infer binding type from iterable
	let elemType = unknownType();
	const iterType = d.forOfIterable.nodeType;
	if (iterType !== null) {
		if ((iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray || iterType.kind === TypeKind.Span) && iterType.typeReturn !== null) {
			elemType = iterType.typeReturn;
		} else if (iterType.kind === TypeKind.String) {
			elemType = charType();
		}
	}
	// Ref parity: for loops — conservative, loop may not execute
	const oldInitState = saveInitState(ctx.initTracker);
	const saved = enterLoopScope(ctx);
	if (d.forOfPattern !== null) {
		// Destructured for-of: define symbols for each pattern element
		defineForOfPatternBindings(ctx, d.forOfPattern, iterType, d.forOfIsConst);
	} else {
		const forSym = makeSymbol(d.forOfBinding, SymbolKind.Variable, elemType, !d.forOfIsConst);
		defineSymbol(ctx.table, forSym);
		// Loop binding is always initialized (iterator provides the value)
		markInitialized(ctx.initTracker, d.forOfBinding);
		sgRecordSym(ctx, d.bindingLocation.line, d.bindingLocation.column, d.bindingLocation.column + d.forOfBinding.length, forSym, elemType, SymbolKind.Variable, d.forOfBinding, "", true);
	}
	checkStmt(ctx, d.forOfBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldInitState);
}

function defineForOfPatternBindings(ctx: CheckerContext, pattern: Node, iterType: Type, isConst: boolean): void {
	if (pattern.kind === NodeKind.ArrayPattern) {
		const apd = pattern.data as ArrayPatternData;
		let i = 0;
		while (i < apd.patternElements.length) {
			const elem = apd.patternElements[i];
			if (elem.kind === NodeKind.Identifier) {
				const id = elem.data as IdentifierData;
				if (id.name !== "_") {
					let elemType = unknownType();
					if (iterType !== null && iterType.kind === TypeKind.Tuple && iterType.typeChildren !== null && i < iterType.typeChildren.length) {
						elemType = iterType.typeChildren[i];
					} else if (iterType !== null && (iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray) && iterType.typeReturn !== null) {
						// Array of tuples: element type from tuple children
						const tupleType = iterType.typeReturn;
						if (tupleType !== null && tupleType.kind === TypeKind.Tuple && tupleType.typeChildren !== null && i < tupleType.typeChildren.length) {
							elemType = tupleType.typeChildren[i];
						}
					}
					defineSymbol(ctx.table, makeSymbol(id.name, SymbolKind.Variable, elemType, !isConst));
					markInitialized(ctx.initTracker, id.name);
				}
			}
			i += 1;
		}
	} else if (pattern.kind === NodeKind.ObjectPattern) {
		const opd = pattern.data as ObjectPatternData;
		for (const prop of opd.patternProps) {
			if (prop.kind !== NodeKind.ObjectPatternProp) continue;
			const p = prop.data as ObjectPatternPropData;
			if (p.propAlias.kind === NodeKind.Identifier) {
				const id = p.propAlias.data as IdentifierData;
				defineSymbol(ctx.table, makeSymbol(id.name, SymbolKind.Variable, unknownType(), !isConst));
				markInitialized(ctx.initTracker, id.name);
			}
		}
	}
}

function checkForInStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForInStmtData;
	checkExpr(ctx, d.forInObject, null);
	const oldInitState = saveInitState(ctx.initTracker);
	const saved = enterLoopScope(ctx);
	defineSymbol(ctx.table, makeSymbol(d.forInBinding, SymbolKind.Variable, unknownType(), !d.forInIsConst));
	markInitialized(ctx.initTracker, d.forInBinding);
	checkStmt(ctx, d.forInBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldInitState);
}

function checkDoWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as DoWhileStmtData;
	// Ref parity: do-while body always executes once — propagate inits (no conservative restore)
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.doBody);
	exitLoopScope(ctx, saved);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
	checkExpr(ctx, d.doCondition, null);
}

function checkBlock(ctx: CheckerContext, node: Node): void {
	const d = node.data as BlockStmtData;
	openScope(ctx.table, ScopeKind.Block);
	const snap = saveFacts(ctx);
	const guardSyms: Symbol[] = [];
	const guardSaved: Type[] = [];
	let i = 0;
	while (i < d.statements.length) {
		if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { break; }
		const stmt = d.statements[i];
		checkStmt(ctx, stmt);

		// Guard clause: if (x === null) return; → NOT(condition) holds for rest of block
		if (stmt.kind === NodeKind.IfStmt) {
			const guardD = stmt.data as IfStmtData;
			if (guardD.alternate === null && isDefiniteExit(guardD.consequent)) {
				addFactNeg(ctx, guardD.condition);
				const vars = extractNullCheckedVars(guardD.condition);
				applyNarrowing(ctx, vars, guardSyms, guardSaved);
			}
		}
		i = i + 1;
	}
	restoreNarrowing(guardSyms, guardSaved);
	restoreFacts(ctx, snap);
	closeScope(ctx.table);
}

function checkReturnStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (ctx.currentFunction === null) {
		addError(ctx, "return outside of function", node.location.line, node.location.column);
	}
	if (d.argument === null) return;

	// Stamp `return null` with the function's declared return type so codegen knows the type.
	if (d.argument.kind === NodeKind.NullLiteral) {
		if (ctx.currentFunction !== null
			&& ctx.currentFunction.symbolType.kind === TypeKind.Function
			&& ctx.currentFunction.symbolType.typeReturn !== null) {
			d.argument.nodeType = ctx.currentFunction.symbolType.typeReturn;
		}
		return;
	}

	// Pass declared return type as expectedType (Implementation parity)
	// Inside match expression block arms, return targets the match — not the function
	let returnExpected: Type = null;
	if (ctx.matchExprDepth === 0
		&& ctx.currentFunction !== null
		&& ctx.currentFunction.symbolType.kind === TypeKind.Function
		&& ctx.currentFunction.symbolType.typeReturn !== null
		&& ctx.currentFunction.symbolType.typeReturn.kind !== TypeKind.Unknown) {
		returnExpected = ctx.currentFunction.symbolType.typeReturn;
	}
	const retType = checkExpr(ctx, d.argument, returnExpected);
	// Parity: standard reference node fitting — insert HiddenStdConv for narrowing return
	if (returnExpected !== null) {
		d.argument = fitNode(ctx, d.argument, returnExpected, retType);
	}
	// Track inferred return type (first return wins)
	if (ctx.matchExprDepth === 0 && ctx.inferredReturn !== null && ctx.inferredReturn.kind === TypeKind.Unknown) {
		ctx.inferredReturn = retType;
	}
	// Check against declared return type (skip inside match expression block arms —
	// return targets the match result, not the enclosing function)
	if (ctx.matchExprDepth === 0
		&& ctx.currentFunction !== null
		&& ctx.currentFunction.symbolType.kind === TypeKind.Function
		&& ctx.currentFunction.symbolType.typeReturn !== null
		&& ctx.currentFunction.symbolType.typeReturn.kind !== TypeKind.Unknown
		&& retType.kind !== TypeKind.Unknown
		&& retType.kind !== TypeKind.Error) {
		// Async functions: declared return is Promise<T>, actual return is T — unwrap for comparison.
		// Only unwrap for async functions (flagged via SymbolFlag) to avoid false accept on non-async Promise returns.
		let declaredReturn = ctx.currentFunction.symbolType.typeReturn;
		if (isPromise(declaredReturn) && getPromiseInner(declaredReturn) !== null
			&& hasFlag(ctx.currentFunction, SymbolFlag.Async)) {
			declaredReturn = getPromiseInner(declaredReturn);
		}
		if (!isAssignable(retType, declaredReturn)) {
			const got = formatTypeBrief(retType);
			const expected = formatTypeBrief(declaredReturn);
			addError(ctx, "Return type mismatch in '" + ctx.currentFunction.name + "': expected " + expected + ", got " + got, node.location.line, node.location.column);
		}
	}
}

function checkTryCatch(ctx: CheckerContext, node: Node): void {
	const d = node.data as TryCatchStmtData;
	// Ref parity: trackTryStmt (sempass2 lines 524-597) — merge try + except
	const oldState = saveInitState(ctx.initTracker);
	const oldInTry = ctx.inTryExpr;
	if (d.catchBody !== null) ctx.inTryExpr = true;
	checkStmt(ctx, d.tryBody);
	ctx.inTryExpr = oldInTry;
	const branchInits: string[][] = [collectNewInits(ctx.initTracker, oldState)];
	const branchBreaks: BreakState[] = [breaksBlock(d.tryBody)];

	if (d.catchBody !== null) {
		restoreInitState(ctx.initTracker, oldState);
		openScope(ctx.table, ScopeKind.Block);
		if (d.catchName !== "") {
			const catchSym = makeSymbol(d.catchName, SymbolKind.Variable, unknownType(), false);
			defineSymbol(ctx.table, catchSym);
			// Catch param is always initialized (exception runtime provides it)
			markInitialized(ctx.initTracker, d.catchName);
			sgRecordSym(ctx, d.catchBindingLocation.line, d.catchBindingLocation.column, d.catchBindingLocation.column + d.catchName.length, catchSym, unknownType(), SymbolKind.Variable, d.catchName, "", true);
		}
		checkStmt(ctx, d.catchBody);
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(d.catchBody));
		closeScope(ctx.table);
	}

	// Merge: intersection of try + catch
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, d.catchBody !== null);

	if (d.finallyBody !== null) {
		checkStmt(ctx, d.finallyBody);
	}
}

function checkSwitchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as SwitchStmtData;
	checkExpr(ctx, d.switchDisc, null);
	// Ref parity: trackCase (sempass2 lines 809-845)
	const oldState = saveInitState(ctx.initTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	let hasDefault = false;
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		if (cd.caseTests.length === 0) hasDefault = true;
		restoreInitState(ctx.initTracker, oldState);
		for (const t of cd.caseTests) { checkExpr(ctx, t, null); }
		for (const s of cd.caseStmts) { checkStmt(ctx, s); }
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		// Build a block from case stmts to check break state
		if (cd.caseStmts.length > 0) {
			branchBreaks.push(breaksBlock(cd.caseStmts[cd.caseStmts.length - 1]));
		} else {
			branchBreaks.push(BreakState.BsNone);
		}
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, hasDefault);
}

function checkMatchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as MatchStmtData;
	const discType = checkExpr(ctx, d.matchStmtDisc, null);
	let hasWildcard = false;
	const coveredMembers: string[] = [];

	// Detect discriminated union narrowing: match (base.discriminantField)
	let narrowBase: Symbol = null;
	let narrowUnion: Type = null;
	if (d.matchStmtDisc.kind === NodeKind.MemberExpr) {
		const discMd = d.matchStmtDisc.data as MemberExprData;
		if (discMd.object !== null && discMd.object.kind === NodeKind.Identifier) {
			const baseSym = lookupSymbol(ctx.table, (discMd.object.data as IdentifierData).name);
			if (baseSym !== null && baseSym.symbolType !== null && isDiscriminatedUnion(baseSym.symbolType) && getDiscriminantName(baseSym.symbolType) === discMd.property) {
				narrowBase = baseSym;
				narrowUnion = baseSym.symbolType;
			}
		}
	}

	const oldState = saveInitState(ctx.initTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	for (const c of d.matchStmtCases) {
		const cd = c.data as MatchCaseData;
		restoreInitState(ctx.initTracker, oldState);
		const hasGuard = cd.caseGuard !== null;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				if (!hasGuard) hasWildcard = true;
				p.nodeType = discType;
			} else {
				if (p.kind === NodeKind.MemberExpr && !hasGuard) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				checkExpr(ctx, p, discType);
			}
		}

		// Variant narrowing
		let savedNarrowType: Type = null;
		if (narrowBase !== null && cd.casePatterns.length === 1) {
			const pat = cd.casePatterns[0];
			let patEnumName = "";
			if (pat.kind === NodeKind.MemberExpr) {
				patEnumName = (pat.data as MemberExprData).property;
			} else if (pat.kind === NodeKind.Identifier && pat.resolvedSym !== null) {
				patEnumName = pat.resolvedSym.name;
			}
			if (patEnumName !== "") {
				const variantIdx = findVariantByDiscriminant(narrowUnion, patEnumName);
				if (variantIdx >= 0 && narrowUnion.typeChildren !== null && variantIdx < narrowUnion.typeChildren.length) {
					savedNarrowType = narrowBase.symbolType;
					narrowBase.symbolType = narrowUnion.typeChildren[variantIdx];
				}
			}
		}

		if (cd.caseGuard !== null) {
			checkExpr(ctx, cd.caseGuard, null);
		}
		checkStmt(ctx, cd.caseBody);

		if (savedNarrowType !== null) {
			narrowBase.symbolType = savedNarrowType;
		}

		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(cd.caseBody));
	}
	checkDuplicatePatterns(ctx, d.matchStmtCases);

	// Match is exhaustive if has wildcard (_) or covers all enum members
	let isExhaustive = hasWildcard;
	if (!isExhaustive && discType.kind === TypeKind.Enum) {
		let allCovered = true;
		for (const member of discType.typeNames) {
			let found = false;
			for (const c of coveredMembers) {
				if (c === member) { found = true; }
			}
			if (!found) { allCovered = false; }
		}
		if (allCovered && discType.typeNames.length > 0) isExhaustive = true;
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, isExhaustive);
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		checkEnumExhaustiveness(ctx, discType, coveredMembers);
	}
}

// ===== Function Body Checker =====

// Unified function body checker — works for FunctionDecl (resolved param types),
// MethodDecl, ConstructorDecl.
// paramLocs: per-param source locations for DEF recording (standard parity: semIdentDef → suggestSym)
export function checkFunctionBody(ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void {
	const savedFunction = ctx.currentFunction;
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.currentFunction = sym;
	ctx.matchExprDepth = 0;
	// Ref parity: trackProc (sempass2 lines 1662-1698) — scope + param init
	const savedBlock = ctx.initTracker.currentBlock;
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	const initSnap = saveInitState(ctx.initTracker);
	openScope(ctx.table, ScopeKind.Function);
	let i = 0;
	for (const param of params) {
		let paramType = unknownType();
		if (sym !== null && sym.symbolType.kind === TypeKind.Function && i < sym.symbolType.typeChildren.length) {
			paramType = sym.symbolType.typeChildren[i];
		}
		const paramSym = makeSymbol(param, SymbolKind.Parameter, paramType, false);
		// Set declaration location for go-to-definition
		if (paramLocs !== null && i < paramLocs.length && paramLocs[i] !== null) {
			paramSym.location = paramLocs[i];
		}
		// Receiver is implicitly LENT (borrowed)
		if (param === "this" || (i === 0 && param === "self")) {
			setFlag(paramSym, SymbolFlag.Lent);
		}
		defineSymbol(ctx.table, paramSym);
		// Ref parity: params are implicitly initialized
		markInitialized(ctx.initTracker, param);
		// Record param DEF for LSP (standard parity: semIdentDef → suggestSym)
		if (paramLocs !== null && i < paramLocs.length && paramLocs[i] !== null) {
			sgRecordSym(ctx, paramLocs[i].line, paramLocs[i].column,
				paramLocs[i].column + param.length,
				paramSym, paramType, SymbolKind.Parameter, param, "", true);
		}
		i += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		checkStmt(ctx, body);
	} else {
		// Expression body (arrow functions) — infer return type
		const exprType = checkExpr(ctx, body, null);
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	// Restore init tracking state
	restoreInitState(ctx.initTracker, initSnap);
	ctx.initTracker.currentBlock = savedBlock;
	ctx.currentFunction = savedFunction;
	ctx.matchExprDepth = savedMatchDepth;
}

function enterLoopScope(ctx: CheckerContext): boolean {
	const saved = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	return saved;
}

function exitLoopScope(ctx: CheckerContext, saved: boolean): void {
	closeScope(ctx.table);
	ctx.inLoop = saved;
}

function checkDestructuringDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as DestructuringDeclData;
	checkExpr(ctx, d.destrInit, null);
}

// ===== Check Program Body =====

export function checkProgramBody(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) return;
		checkStmt(ctx, stmt);
	}
}

// ===== Main Entry Point =====

// Run all 3 passes on a program node with an existing context
export function runThreePasses(ctx: CheckerContext, program: Node): void {
	collectTopLevel(ctx, program);
	resolveDeclarations(ctx, program);
	checkProgramBody(ctx, program);
}

// Process a single MacroInvocation node as a directive (@include/@link/@passC/@passL).
function collectOneDirective(ctx: CheckerContext, mi: Node): void {
	if (mi.kind !== NodeKind.MacroInvocation) return;
	const md = mi.data as MacroInvocationData;
	if (md.macroArgs.length === 0 || md.macroArgs[0].kind !== NodeKind.StringLiteral) return;
	const sd = md.macroArgs[0].data as StringLiteralData;
	const name = md.macroName;
	if (name === "include") {
		if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
		ctx.includeDirectives = ctx.includeDirectives + sd.value;
		const modDir = getModuleDir(ctx.modulePath);
		if (modDir !== "") ctx.compilerFlags = appendFlag(ctx.compilerFlags, "-iquote" + modDir);
	} else if (name === "compile") {
		if (ctx.compileDirectives !== "") ctx.compileDirectives = ctx.compileDirectives + "\n";
		// Per-file custom flags: @compile("file.c", "-O3") → "file.c\t-O3" (tab-separated)
		let entry = sd.value;
		if (md.macroArgs.length >= 2 && md.macroArgs[1].kind === NodeKind.StringLiteral) {
			const flagsArg = md.macroArgs[1].data as StringLiteralData;
			entry = entry + "\t" + flagsArg.value;
		}
		ctx.compileDirectives = ctx.compileDirectives + entry;
	} else if (name === "passC") {
		ctx.compilerFlags = appendFlag(ctx.compilerFlags, sd.value);
	} else if (name === "link") {
		// Resolve @link paths relative to declaring module's directory (like @compile).
		// Prepend to link list (reference-aligned: linked first, like addExternalFileToLink).
		const modDir = getModuleDir(ctx.modulePath);
		const resolved = modDir !== "" ? modDir + "/" + sd.value : sd.value;
		ctx.linkFlags = prependFlag(ctx.linkFlags, resolved);
	} else if (name === "passL") {
		// No dedup (reference-aligned: addLinkOption is simple append).
		ctx.linkFlags = concatFlag(ctx.linkFlags, sd.value);
	}
}

// Extract @include/@link/@passC/@passL directives from program AST into context.
// Handles both standalone directives (@name("x");) and decorators (@name("x") decl).
export function collectDirectives(ctx: CheckerContext, program: Node): void {
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		if (stmt.kind === NodeKind.ExprStmt) {
			const d = stmt.data as ExprStmtData;
			collectOneDirective(ctx, d.expr);
		} else if (stmt.kind === NodeKind.DecoratedDecl) {
			const dd = stmt.data as DecoratedDeclData;
			for (const dec of dd.decorators) {
				collectOneDirective(ctx, dec);
			}
		}
	}
}

// Stamp @include headers on all ImportC symbols in current scope.
// Called after collectDirectives so ctx.includeDirectives is populated.
export function stampHeaderPaths(ctx: CheckerContext): void {
	if (ctx.includeDirectives === "") return;
	const scope = ctx.table.current;
	for (const sym of scope.symbols) {
		if (hasFlag(sym, SymbolFlag.ImportC) && sym.headerPath === "") {
			sym.headerPath = ctx.includeDirectives;
		}
	}
}

function defineBuiltinConstants(ctx: CheckerContext): void {
	const nanSym = makeSymbol("NaN", SymbolKind.Variable, float64Type(), false);
	nanSym.state = SymbolState.Checked;
	nanSym.builtinKind = "NaN";
	defineSymbol(ctx.table, nanSym);
	const infSym = makeSymbol("Infinity", SymbolKind.Variable, float64Type(), false);
	infSym.state = SymbolState.Checked;
	infSym.builtinKind = "Infinity";
	defineSymbol(ctx.table, infSym);
}

// ===== Unified Prelude Loading (reference parity: single pipeline) =====

// Load a single prelude module into a context. Shared by all paths.
function loadPreludeOne(ctx: CheckerContext, specifier: string, stdPath: string): void {
	const base = stdPath.length > 0 ? stdPath + "/" + specifier.slice(4, specifier.length) : specifier;
	let src = readFile(base + ".ms");
	let resolvedPath = base + ".ms";
	if (src.length === 0) {
		src = readFile(base + "/index.cms");
		resolvedPath = base + "/index.cms";
	}
	if (src.length === 0) {
		src = readFile(base + "/index.ms");
		resolvedPath = base + "/index.ms";
	}
	if (src.length > 0) {
		const pr = parseSource(src);
		if (pr.ok) {
			// Set modulePath BEFORE sub-module loading so path resolution is consistent
			const savedPath = ctx.modulePath;
			ctx.modulePath = resolvedPath;

			// Load sub-modules first (dependency-first, recursive compilation)
			// Register sub-module exports in ExportRegistry so index.cms re-exports resolve
			loadPreludeSubModules(ctx, pr.value, resolvedPath, stdPath);
			runThreePasses(ctx, pr.value);
			ctx.modulePath = savedPath;
			collectDirectives(ctx, pr.value);
			stampHeaderPaths(ctx);
			const scope = ctx.table.current;
			for (const sym of scope.symbols) {
				ensureShaped(sym, ctx);
				for (const ov of sym.overloads) {
					ensureShaped(ov, ctx);
				}
			}
		}
	}
}

// Load prelude sub-modules referenced by re-exports (export { X } from "./sub")
// Reference-aligned: each sub-module is fully compiled (3 passes) before the parent.
// Exports are registered in ExportRegistry so the parent's collectImport resolves them.
// Note: compile.ms loadPreludeModules also loads these into the module graph for codegen.
// Both paths are needed: checker needs types early, codegen needs compiled C later.
function loadPreludeSubModules(ctx: CheckerContext, program: Node, indexPath: string, stdPath: string): void {
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const dir = getModuleDir(indexPath);
	if (dir === "") return;

	for (const stmt of pd.programStmts) {
		if (stmt.kind !== NodeKind.ExportDecl) continue;
		const ed = stmt.data as ExportDeclData;
		if (ed.exportedDecl === null) continue;
		if (ed.exportedDecl.kind !== NodeKind.ImportDecl) continue;
		const id = ed.exportedDecl.data as ImportDeclData;
		// Only relative imports (./sub or ../sub)
		if (id.importSource.length < 2 || id.importSource.charAt(0) !== ".") continue;

		// Resolve path relative to index file (strip ./ prefix)
		let importRel = id.importSource;
		if (importRel.length > 2 && importRel.slice(0, 2) === "./") {
			importRel = importRel.slice(2, importRel.length);
		}
		const subPath = dir + "/" + importRel;
		let subSrc = readFile(subPath + ".ms");
		let subResolved = subPath + ".ms";
		if (subSrc.length === 0) {
			subSrc = readFile(subPath + ".cms");
			subResolved = subPath + ".cms";
		}
		if (subSrc.length === 0) continue;
		const subPr = parseSource(subSrc);
		if (!subPr.ok) continue;

		// Compile sub-module in a temporary context (separate scope, shared cache)
		const subCtx = createContextWithCache(ctx.table.identCache);
		subCtx.extensionRegistry = createExtensionRegistry();
		subCtx.exportRegistry = ctx.exportRegistry;
		// Inject prelude symbols so sub-module can reference them
		for (const sym of ctx.table.current.symbols) {
			subCtx.table.current.symbols.push(sym);
		}
		// Copy parent extensions so sub-module can use string/array methods
		if (ctx.extensionRegistry !== null) {
			for (const ext of ctx.extensionRegistry.methods) {
				registerExtension(subCtx.extensionRegistry, ext);
			}
		}
		openScope(subCtx.table, ScopeKind.Module);
		subCtx.modulePath = subResolved;
		runThreePasses(subCtx, subPr.value);

		// Register sub-module's exported symbols in ExportRegistry
		const subExports: ExportedSymInfo[] = [];
		const subScope = subCtx.table.current;
		for (const sym of subScope.symbols) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				subExports.push(buildExportInfo(sym, subCtx.extensionRegistry, subResolved));
			}
		}
		registerModuleExports(ctx.exportRegistry, subResolved, subExports);
		// Also register without extension so collectImport's relative path resolution finds it
		registerModuleExports(ctx.exportRegistry, subPath, subExports);

		// Also register sub-module extensions into parent context
		if (subCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
			for (const ext of subCtx.extensionRegistry.methods) {
				if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
					registerExtension(ctx.extensionRegistry, ext);
				}
			}
		}
	}
}

// Build a prelude context with all globalImports loaded.
// Used by both standalone checkProgram and orchestrator.
// Creates a shared IdentCache (one cache per compilation)
// that must be passed to all module contexts in the same compilation.
export function buildPreludeContext(stdPath: string): CheckerContext {
	const cache = createIdentCache();
	const ctx = createContextWithCache(cache);
	ctx.extensionRegistry = createExtensionRegistry();
	const imps = globalImports();
	let idx = 0;
	while (idx < imps.length) {
		loadPreludeOne(ctx, imps[idx], stdPath);
		idx = idx + 1;
	}
	return ctx;
}

// Get the shared IdentCache from a prelude context.
export function getSharedIdentCache(ctx: CheckerContext): IdentCache {
	return ctx.table.identCache;
}

// Inject exported prelude symbols, extensions, and directives into a module context.
// NOTE: Uses while loops (not for-of) so DRC properly increfs shared symbols.
// for-of creates cursor bindings that skip RC — pushing cursors into another
// container creates dangling pointers when the source is destroyed.
export function injectPrelude(ctx: CheckerContext, preludeCtx: CheckerContext): void {
	const preludeSyms = preludeCtx.table.current.symbols;
	let si = 0;
	while (si < preludeSyms.length) {
		const sym = preludeSyms[si];
		if (hasFlag(sym, SymbolFlag.Exported)) {
			// With shared IdentCache, nameIds are already consistent
			// across all contexts in the same compilation. No re-interning needed.
			ctx.table.current.symbols.push(sym);
		}
		si = si + 1;
	}
	if (preludeCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
		const preludeExts = preludeCtx.extensionRegistry.methods;
		let ei = 0;
		while (ei < preludeExts.length) {
			const ext = preludeExts[ei];
			if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
				// Imported extensions get scope depth 0 (other module).
				// Don't mutate ext — preludeCtx may be cached across modules (LSP TransAmDb).
				const imported: ExtensionMethod = {
					methodName: ext.methodName,
					receiverTypeName: ext.receiverTypeName,
					sourcePath: ext.sourcePath,
					fnType: ext.fnType,
					isStatic: ext.isStatic,
					sym: ext.sym,
					scopeDepth: 0,
				};
				registerExtension(ctx.extensionRegistry, imported);
			}
			ei = ei + 1;
		}
	}
	if (preludeCtx.includeDirectives !== "") {
		if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
		ctx.includeDirectives = ctx.includeDirectives + preludeCtx.includeDirectives;
	}
	// NOTE: compileDirectives are NOT merged per-module. They are processed once
	// from the prelude context in cmdBuildC. Merging would cause each of N modules
	// to re-compile the same native.c files, producing N×M duplicate symbols.
	if (preludeCtx.compilerFlags !== "") {
		ctx.compilerFlags = appendFlag(ctx.compilerFlags, preludeCtx.compilerFlags);
	}
	if (preludeCtx.linkFlags !== "") {
		ctx.linkFlags = concatFlag(ctx.linkFlags, preludeCtx.linkFlags);
	}
}

// Single internal entry point for all checkProgram variants.
function checkProgramCore(
	program: Node,
	preludeCtx: CheckerContext,
	registry: ExportRegistry,
	graph: ModuleGraph,
	mod: Module,
	cancelCtx: CancelCtx,
	cancelVersion: number,
): CheckerContext {
	// Use shared IdentCache from prelude (one cache per compilation)
	const sharedCache = preludeCtx.table.identCache;
	const ctx = mod !== null ? createModuleContextWithCache(graph, mod, sharedCache) : createContextWithCache(sharedCache);
	ctx.extensionRegistry = createExtensionRegistry();
	if (registry !== null) ctx.exportRegistry = registry;  // override empty default with caller's registry
	if (cancelCtx !== null) { ctx.cancelCtx = cancelCtx; ctx.cancelVersion = cancelVersion; }
	injectPrelude(ctx, preludeCtx);
	ctx.preludeCtx = preludeCtx;  // friend modules — access private prelude symbols during instantiation
	const consoleClass = lookupSymbol(ctx.table, "console");
	if (consoleClass !== null) {
		const consoleGlobal = makeSymbol("console", SymbolKind.Variable, consoleClass.symbolType, false);
		defineSymbol(ctx.table, consoleGlobal);
		consoleGlobal.state = SymbolState.Shaped;
	}
	const promiseClass = lookupSymbol(ctx.table, "Promise");
	if (promiseClass !== null) {
		const promiseGlobal = makeSymbol("Promise", SymbolKind.Variable, promiseClass.symbolType, false);
		defineSymbol(ctx.table, promiseGlobal);
		promiseGlobal.state = SymbolState.Shaped;
	}
	defineBuiltinConstants(ctx);
	openScope(ctx.table, ScopeKind.Module);
	runThreePasses(ctx, program);
	collectDirectives(ctx, program);
	stampHeaderPaths(ctx);
	inferOwnership(ctx, program);
	analyzeParamMutations(ctx, program);
	sgSortRecords(ctx.symRecords);
	return ctx;
}

// ===== Public API =====

// Convenience wrapper — creates empty registry. For inline tests and CLI tools
// that don't need cross-module resolution.
export function checkProgram(program: Node): CheckerContext {
	const preludeCtx = buildPreludeContext("");
	return checkProgramCore(program, preludeCtx, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, null as unknown as CancelCtx, 0);
}

export function checkProgramWithRegistry(program: Node, registry: ExportRegistry, graph: ModuleGraph, mod: Module, preludeCtx: CheckerContext): CheckerContext {
	return checkProgramCore(program, preludeCtx, registry, graph, mod, null as unknown as CancelCtx, 0);
}

export function checkProgramWithRegistryCancellable(
	program: Node, registry: ExportRegistry,
	graph: ModuleGraph, mod: Module,
	preludeCtx: CheckerContext,
	cancelCtx: CancelCtx, cancelVersion: number
): CheckerContext {
	return checkProgramCore(program, preludeCtx, registry, graph, mod, cancelCtx, cancelVersion);
}

// Register callbacks at module load time
registerCheckStmt((ctx: CheckerContext, node: Node): void => { checkStmt(ctx, node); });
registerCheckFunctionBody((ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void => { checkFunctionBody(ctx, sym, params, body, paramLocs); });

// ===== Tests =====

export function checkSource(input: string): CheckerContext {
	const pr = parseSource(input);
	if (!pr.ok) return createContext();
	return checkProgram(pr.value);
}

function checkOk(input: string): boolean {
	const ctx = checkSource(input);
	return !hasErrors(ctx);
}

function checkErrors(input: string): number {
	const ctx = checkSource(input);
	return errorCount(ctx);
}

test "variable decl" {
	assert checkOk("const x = 1;");
	assert checkOk("let y = 2;");
	assert checkOk("var z = 3;");
}

test "variable use" { assert checkOk("const x = 1; const y = x;"); }

test "undefined variable" {
	assert !checkOk("const x = y;");
	assert checkErrors("const x = y;") === 1;
}

test "function scope" { assert checkOk("function foo(a, b) { const x = a; }"); }

test "forward reference" { assert checkOk("const x = foo; function foo() { return 1; }"); }

test "block scope" { assert checkOk("const x = 1; if (true) { const y = x; }"); }

test "nested scope isolation" { assert !checkOk("if (true) { const y = 1; } const z = y;"); }

test "break in loop" { assert checkOk("while (true) { break; }"); }

test "break outside loop" { assert !checkOk("break;"); }

test "continue in loop" { assert checkOk("for (let i = 0; i < 10; i++) { continue; }"); }

test "continue outside loop" { assert !checkOk("continue;"); }

test "for-of binding" { assert checkOk("const items = 1; for (const item of items) { const x = item; }"); }

test "return in function" { assert checkOk("function foo() { return 1; }"); }

test "return outside function" { assert !checkOk("return 1;"); }

test "class method scope" { assert checkOk("class Foo { bar(x) { return x; } }"); }

test "try-catch param" { assert checkOk("try { const x = 1; } catch (e) { const y = e; }"); }

test "arrow function" { assert checkOk("const f = (x) => x;"); }

test "number type" {
	const ctx = checkSource("const x = 42;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "string type" {
	const ctx = checkSource("const s = \"hello\";");
	const sym = lookupSymbol(ctx.table, "s");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "boolean type" {
	const ctx = checkSource("const b = true;");
	const sym = lookupSymbol(ctx.table, "b");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "null type" {
	const ctx = checkSource("const n = null;");
	const sym = lookupSymbol(ctx.table, "n");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Null;
}

test "arithmetic returns number" {
	const ctx = checkSource("const x = 1 + 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "string concat returns string" {
	const ctx = checkSource("const x = \"a\" + \"b\";");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "comparison returns boolean" {
	const ctx = checkSource("const x = 1 < 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "equality returns boolean" {
	const ctx = checkSource("const x = 1 === 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "negation returns boolean" {
	const ctx = checkSource("const x = !true;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "unary minus returns number" {
	const ctx = checkSource("const x = -5;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "function has Function type after resolve" {
	const ctx = checkSource("function foo(a, b) { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren.length === 2;
	assert sym.symbolType.typeNames.length === 2;
}

test "call returns function return type" {
	const ctx = checkSource("function foo(a, b) { return 1; } const x = foo(1, 2);");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	// foo's return type inferred as number from body
	assert sym.symbolType.kind === TypeKind.Number;
}

test "forward reference to function is callable" {
	const ctx = checkSource("const x = foo(1); function foo(a) { return 1; }");
	assert !hasErrors(ctx);
}

test "typed function params resolved" {
	const ctx = checkSource("function add(a: number, b: number): number { return a; }");
	const sym = lookupSymbol(ctx.table, "add");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind === TypeKind.Number;
	assert sym.symbolType.typeChildren[1].kind === TypeKind.Number;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "typed function call returns annotated type" {
	const ctx = checkSource("function greet(name: string): string { return name; } const x = greet(\"hi\");");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "array literal infers element type" {
	const ctx = checkSource("const arr = [1, 2, 3];");
	const sym = lookupSymbol(ctx.table, "arr");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Array;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "arrow function has Function type" {
	const ctx = checkSource("const f = (x) => x;");
	const sym = lookupSymbol(ctx.table, "f");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
}

test "inferred return type from body" {
	const ctx = checkSource("function foo() { return 42; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "annotated return type preserved" {
	const ctx = checkSource("function bar(): string { return \"hi\"; }");
	const sym = lookupSymbol(ctx.table, "bar");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.String;
}

test "arrow infers return type" {
	const ctx = checkSource("const f = (x) => 42;");
	const sym = lookupSymbol(ctx.table, "f");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.Number;
}

test "string return inferred" {
	const ctx = checkSource("function greet() { return \"hello\"; }");
	const sym = lookupSymbol(ctx.table, "greet");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.String;
}

test "boolean return inferred" {
	const ctx = checkSource("function isOk() { return true; }");
	const sym = lookupSymbol(ctx.table, "isOk");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.Boolean;
}

test "no return stays unknown" {
	const ctx = checkSource("function noop() { const x = 1; }");
	const sym = lookupSymbol(ctx.table, "noop");
	assert sym !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.Unknown;
}

test "return type mismatch detected" { assert !checkOk("function foo(): number { return \"hello\"; }"); }

test "return type match ok" { assert checkOk("function foo(): number { return 42; }"); }

test "return string match ok" { assert checkOk("function bar(): string { return \"hi\"; }"); }

test "arg type mismatch detected" { assert !checkOk("function add(a: number, b: number): number { return a; } const x = add(\"hi\", 2);"); }

test "arg type match ok" { assert checkOk("function add(a: number, b: number): number { return a; } const x = add(1, 2);"); }

test "numeric widening ok" { assert checkOk("function f(n: number): number { return n; } const x = f(42);"); }

test "two overloads no error" { assert checkOk("function add(a: number, b: number): number { return a; } function add(a: string, b: string): string { return a; }"); }

test "overload different arity no error" { assert checkOk("function f(a: number): number { return a; } function f(a: number, b: number): number { return a; }"); }

test "overload call resolves" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const x = f(1);");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "overload call picks string version" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const y = f(\"hi\");");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "y");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "no match reports error" {
	const ctx = checkSource("function add(a: number, b: number): number { return a; } function add(a: string, b: string): string { return a; } const x = add(true);");
	assert hasErrors(ctx);
}

test "ambiguous call reports error" {
	// Same param types, different return types → ambiguous
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: number): string { return \"hi\"; } const x = f(1);");
	assert hasErrors(ctx);
}

test "arity-based overload resolution" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: number, b: number): number { return a; } const x = f(1); const y = f(1, 2);");
	assert !hasErrors(ctx);
}

test "two extension overloads no error" { assert checkOk("function trim(this s: string): string { return s; } function trim(this s: string, ch: string): string { return s; }"); }

test "extension overload call resolves by arity" {
	const ctx = checkSource("function double(this n: number): number { return n; } function double(this n: number, scale: number): number { return n; } const x = double(1); const y = double(1, 2);");
	assert !hasErrors(ctx);
}

test "same-name extensions on different types filter by receiver" {
	// Bug repro: indexOf on string vs number[] — must resolve by receiver type, not pick first match
	const ctx = checkSource("function indexOf(this s: string, sub: string, start: number): number { return 0; } function indexOf(this arr: number[], value: number): number { return 0; } const msg: string = \"hello\"; const idx: number = msg.indexOf(\"world\", 0);");
	assert !hasErrors(ctx);
}

test "same-name extensions array receiver resolves correctly" {
	const ctx = checkSource("function indexOf(this s: string, sub: string, start: number): number { return 0; } function indexOf(this arr: number[], value: number): number { return 0; } const a: number[] = [1, 2, 3]; const idx: number = a.indexOf(42);");
	assert !hasErrors(ctx);
}

test "generic extension matches compatible array receiver" {
	// first<T>(this arr: T[]) called as a.first() — T unifies with number
	const ctx = checkSource("function first<T>(this arr: T[]): T { return arr[0]; } const a: number[] = [1, 2]; const x: number = a.first();");
	assert !hasErrors(ctx);
}

test "extension method registered" {
	const ctx = checkSource("function trim(this s: string): string { return s; }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "trim");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
}

test "extension method callable as function" {
	const ctx = checkSource("function double(this n: number): number { return n; } const x = double(1);");
	assert !hasErrors(ctx);
}

test "extension on builtin type no error" { assert checkOk("function len(this s: string): number { return 0; }"); }

test "generic function parses ok" { assert checkOk("function wrap<T>(x: T): T { return x; }"); }

test "generic param resolved as GenericParam" {
	const ctx = checkSource("function id<T>(x: T): T { return x; }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "id");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind === TypeKind.GenericParam;
	assert sym.symbolType.typeReturn.kind === TypeKind.GenericParam;
}

test "generic call infers return type" {
	const ctx = checkSource("function id<T>(x: T): T { return x; } const n = id(42);");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "n");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "two generic params" {
	const ctx = checkSource("function first<T, U>(a: T, b: U): T { return a; } const x = first(1, \"hi\");");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "generic with annotated return" { assert checkOk("function identity<T>(x: T): T { return x; }"); }

test "wildcard always exhaustive" { assert checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { _ => 0 }; }"); }

test "all members covered" { assert checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2, Color.Blue => 3 }; }"); }

test "missing member errors" { assert !checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2 }; }"); }

test "binding acts as wildcard" { assert checkOk("enum Color { Red, Green } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, other => 0 }; }"); }

test "non-enum no exhaustiveness check" { assert checkOk("const x = match (42) { 1 => \"one\", _ => \"other\" };"); }

test "match expr returns arm type" {
	const ctx = checkSource("const x = match (1) { 1 => 42, _ => 0 };");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "basic not-null check" { assert checkOk("const x = 1; if (x !== null) { const y = x; }"); }

test "reversed null check" { assert checkOk("const x = 1; if (null !== x) { const y = x; }"); }

test "equals null narrows" { assert checkOk("const x = 1; if (x === null) { const y = x; }"); }

test "no narrowing without null check" { assert checkOk("const x = 1; if (x === x) { const y = x; }"); }

test "removeNullFromType unit" {
	const unionType = createUnion([stringType(), nullType()]);
	const narrowed = removeNullFromType(unionType);
	assert narrowed.kind === TypeKind.String;
}

test "guard clause narrows after early return" {
	// if (x === null) return; → x should be non-null after
	assert checkOk("function f(x: string): string { if (x === null) return \"\"; const y = x; return y; }");
}

test "guard clause narrows after throw" { assert checkOk("function f(x: string): string { if (x === null) throw \"err\"; return x; }"); }

test "logical AND null check" {
	// x !== null && x > 0 → x is non-null in consequent
	assert checkOk("const x = 1; if (x !== null && x > 0) { const y = x; }");
}

test "pure function with pure ops passes" { assert checkOk("@pure function add(a: number, b: number): number { return a + b; }"); }

test "pure function calling impure warns" {
	const ctx = checkSource("function impure(): void {} @pure function bad(): void { impure(); }");
	assert hasErrors(ctx);
}

test "pure calling pure is ok" { assert checkOk("@pure function helper(x: number): number { return x; } @pure function main(a: number): number { return helper(a); }"); }

test "type alias resolves to type" {
	const ctx = checkSource("type ID = number;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "ID");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "type alias Result resolved" {
	const ctx = checkSource("type MyResult = Result<number, string>;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "MyResult");
	assert sym !== null;
	assert isResult(sym.symbolType);
}

test "distinct type creates Distinct wrapper" {
	const ctx = checkSource("distinct type UserId = number;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "UserId");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Distinct;
}

test "variable annotation overrides inference" {
	const ctx = checkSource("const x: string = \"hello\";");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "class property type resolved" {
	const ctx = checkSource("class Point { x: number; y: string; getX() { return 1; } }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "Point");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
}

test "decl with default parses ok" { assert checkOk("function f1(x: number, y: number = 5) { return x; }"); }

test "call with all args" { assert checkOk("function f2(x: number, y: number = 5) { return x; } f2(1, 2);"); }

test "call with default fills missing arg" { assert checkOk("function f3(x: number, y: number = 5) { return x; } f3(1);"); }

test "multiple defaults partial fill" { assert checkOk("function f4(a: number, b: number = 1, c: number = 2) { return a; } f4(0);"); }

test "all defaults omitted" { assert checkOk("function f5(x: number = 10) { return x; } f5();"); }

test "string default" { assert checkOk("function f6(x: string = \"hi\") { return x; } f6();"); }

test "boolean default" { assert checkOk("function f7(x: boolean = true) { return x; } f7();"); }

