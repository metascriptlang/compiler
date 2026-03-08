// Statement Checker — Pass 3 statement validation and control flow
// Expression checking extracted to checkExprPass.ms. Uses checkerCallbacks for mutual recursion.

import {
	Node, NodeKind, DeclKind,
	ExprStmtData, ThrowStmtData, DeferStmtData, DecoratedDeclData,
	IdentifierData, BinaryExprData, MemberExprData,
	VariableDeclData, FunctionDeclData, ClassDeclData,
	MethodDeclData, ConstructorDeclData, ExportDeclData,
	IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	DoWhileStmtData, BlockStmtData, ReturnStmtData, TryCatchStmtData,
	SwitchStmtData, SwitchCaseData, MatchStmtData, MatchCaseData,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, ProgramData,
	MacroInvocationData, StringLiteralData, CallExprData,
	TestDeclData, AssertStmtData,
} from "../ast/node";
import {
	Type, TypeKind,
	unknownType, nullType, stringType, charType, numberType, voidType,
	createFunction, createUnion, isMaybeType, unwrapMaybeType,
	isNarrowingIntConv,
} from "./types";
import {
	Symbol, SymbolKind, SymbolState, ScopeKind,
	defineSymbol, lookupSymbol, lookupLocal, makeSymbol, openScope, closeScope,
	setFlag, hasFlag, SymbolFlag,
} from "./symbol";
import { CheckerContext, CancelCtx, createContext, createModuleContext, addError, addFatalError, hasErrors, hasFatalErrors, errorCount, createExtensionRegistry, registerExtension, ExportRegistry, isCancelled } from "./context";
import { Module, ModuleGraph } from "../module/graph";
import { collectTopLevel, defineOrError } from "./collectPass";
import { readFile } from "std/process";
import { globalImports } from "./prelude";
import { isAssignable } from "./compat";
import { resolveDeclarations, resolveAnnotation, ensureShaped } from "./resolvePass";
import { inferOwnership } from "./ownershipInference";
import { validateTypedAST } from "./validate";
import { sliceStr } from "../utils/string";
import { checkExpr, checkEnumExhaustiveness, fitNode } from "./checkExprPass";
import { registerCheckStmt } from "./checkerCallbacks";
import { parseSource } from "../parser/statements/validation";

// ===== Statement Checker =====

export function checkStmt(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.VariableDecl => checkVariableDecl(ctx, node),
		NodeKind.FunctionDecl => checkFunctionDecl(ctx, node),
		NodeKind.ClassDecl => checkClassDecl(ctx, node),
		NodeKind.InterfaceDecl | NodeKind.EnumDecl | NodeKind.TypeAliasDecl |
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
			checkExpr(ctx, d.expr, null as unknown as Type);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			checkExpr(ctx, d.throwArg, null as unknown as Type);
		},
		NodeKind.TryCatchStmt => checkTryCatch(ctx, node),
		NodeKind.SwitchStmt => checkSwitchStmt(ctx, node),
		NodeKind.MatchStmt => checkMatchStmt(ctx, node),
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			checkExpr(ctx, d.deferExpr, null as unknown as Type);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			checkStmt(ctx, d.decoratedNode);
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
			checkExpr(ctx, d.assertExpr, null as unknown as Type);
		},
		_ => {},
	};
}

// ===== Statement Helpers =====

function checkVariableDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	// Resolve declared type FIRST so it can flow as expectedType into initializer (Implementation parity)
	let declType = null as unknown as Type;
	if (d.declType !== "") {
		declType = resolveAnnotation(d.declType, ctx);
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
	} else {
		defineOrError(ctx, makeSymbol(d.declName, SymbolKind.Variable, varType, d.declKind !== DeclKind.Const), node);
	}
}

function checkFunctionDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = lookupSymbol(ctx.table, d.fnName);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Demand-driven: ensure signature is shaped before checking body
	ensureShaped(sym, ctx);

	// Multi-pass parity: avoid re-checking body if already done
	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	const fnType = sym.symbolType;
	node.nodeType = fnType;

	// Save/restore inferredReturn for nested functions
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = fnType.typeReturn;

	checkFunctionBody(ctx, sym, d.params, d.fnBody);

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
	if (node.kind === NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		checkClassMember(ctx, dd.decoratedNode, className, classType);
		return;
	}
	match (node.kind) {
		NodeKind.PropertyDecl => {},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			const methodSym = node.resolvedSym;
			checkFunctionBody(ctx, methodSym !== null ? methodSym : makeSymbol(d.methodName, SymbolKind.Method, unknownType(), false), d.methodParams, d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
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
			checkFunctionBody(ctx, makeSymbol("constructor", SymbolKind.Method, ctorFnType, false), ctorParams, d.ctorBody);
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

// ===== Null Narrowing =====

// Analyze condition for null check: returns "+varName" for !== null, "-varName" for === null, "" for no match
// Also handles: x !== null && expr → "+varName" (logical AND with null check on left)
function analyzeNullCheck(condition: Node): string {
	if (condition.kind !== NodeKind.BinaryExpr) return "";
	const d = condition.data as BinaryExprData;

	// Logical AND: x !== null && ...  → null check on left side
	if (d.operator === "&&") {
		return analyzeNullCheck(d.left);
	}

	// x !== null or x === null
	if (d.left.kind === NodeKind.Identifier && d.right.kind === NodeKind.NullLiteral) {
		const id = d.left.data as IdentifierData;
		if (d.operator === "!==") return "+" + id.name;
		if (d.operator === "===") return "-" + id.name;
	}
	// null !== x or null === x
	if (d.right.kind === NodeKind.Identifier && d.left.kind === NodeKind.NullLiteral) {
		const id = d.right.data as IdentifierData;
		if (d.operator === "!==") return "+" + id.name;
		if (d.operator === "===") return "-" + id.name;
	}
	return "";
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

// Guard clause detection: if (x === null) { return/throw/break/continue } → narrow x for rest of block
// Returns "+varName" if guard narrows to non-null, "" if not a guard clause.
function tryGuardClauseNarrow(ctx: CheckerContext, node: Node): string {
	const d = node.data as IfStmtData;
	const narrowResult = analyzeNullCheck(d.condition);
	if (narrowResult === "") return "";

	const isNotNull = sliceStr(narrowResult, 0, 1) === "+";
	// Guard clause: if (x === null) return; → x is non-null after
	// Guard clause: if (x !== null) { ... } else return; → x is non-null after (but this is handled by if-else narrowing)
	// We only handle: condition is === null AND consequent is definite exit
	if (!isNotNull && isDefiniteExit(d.consequent)) {
		const varName = sliceStr(narrowResult, 1, narrowResult.length);
		return "+" + varName;
	}
	return "";
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
		// Last statement determines exit
		return isDefiniteExit(bd.statements[bd.statements.length - 1]);
	}
	return false;
}

function checkIfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as IfStmtData;
	checkExpr(ctx, d.condition, null as unknown as Type);

	// Analyze condition for null narrowing
	const narrowResult = analyzeNullCheck(d.condition);
	if (narrowResult !== "") {
		const isNotNull = sliceStr(narrowResult, 0, 1) === "+";
		const varName = sliceStr(narrowResult, 1, narrowResult.length);
		const sym = lookupSymbol(ctx.table, varName);
		if (sym !== null && sym.symbolType.kind !== TypeKind.Unknown) {
			const saved = sym.symbolType;
			// Consequent: narrow appropriately
			if (isNotNull) {
				sym.symbolType = removeNullFromType(saved);
			} else {
				sym.symbolType = nullType();
			}
			checkStmt(ctx, d.consequent);
			sym.symbolType = saved;
			// Alternate: opposite narrowing
			if (d.alternate !== null && d.alternate.kind !== NodeKind.NullLiteral) {
				if (isNotNull) {
					sym.symbolType = nullType();
				} else {
					sym.symbolType = removeNullFromType(saved);
				}
				checkStmt(ctx, d.alternate);
				sym.symbolType = saved;
			}
			return;
		}
	}

	// Fallback: no narrowing
	checkStmt(ctx, d.consequent);
	if (d.alternate !== null && d.alternate.kind !== NodeKind.NullLiteral) {
		checkStmt(ctx, d.alternate);
	}
}

// ===== Loop Statements =====

function checkWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as WhileStmtData;
	checkExpr(ctx, d.whileCondition, null as unknown as Type);
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.whileBody);
	exitLoopScope(ctx, saved);
}

function checkForStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForStmtData;
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.forInit);
	checkExpr(ctx, d.forCondition, null as unknown as Type);
	checkExpr(ctx, d.forUpdate, null as unknown as Type);
	checkStmt(ctx, d.forBody);
	exitLoopScope(ctx, saved);
}

function checkForOfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForOfStmtData;
	checkExpr(ctx, d.forOfIterable, null as unknown as Type);
	// Infer binding type from iterable
	let elemType = unknownType();
	const iterType = d.forOfIterable.nodeType;
	if (iterType !== null) {
		if ((iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray || iterType.kind === TypeKind.Span) && iterType.typeReturn !== null) {
			elemType = iterType.typeReturn;
		} else if (iterType.kind === TypeKind.String) {
			elemType = charType();
		} else if (iterType.kind === TypeKind.Set && iterType.typeReturn !== null) {
			elemType = iterType.typeReturn;
		} else if (iterType.kind === TypeKind.Map && iterType.typeReturn !== null) {
			// Non-destructured for-of on Map yields keys
			elemType = iterType.typeReturn;
		}
	}
	const saved = enterLoopScope(ctx);
	if (d.forOfPattern !== null) {
		// Destructured for-of: define symbols for each pattern element
		defineForOfPatternBindings(ctx, d.forOfPattern, iterType, d.forOfIsConst);
	} else {
		defineSymbol(ctx.table, makeSymbol(d.forOfBinding, SymbolKind.Variable, elemType, !d.forOfIsConst));
	}
	checkStmt(ctx, d.forOfBody);
	exitLoopScope(ctx, saved);
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
					if (iterType !== null && iterType.kind === TypeKind.Map) {
						// Map [key, value]: element 0 = key type, element 1 = value type
						if (i === 0) {
							elemType = stringType();
						} else if (i === 1 && iterType.typeReturn !== null) {
							elemType = iterType.typeReturn;
						}
					} else if (iterType !== null && iterType.kind === TypeKind.Tuple && iterType.typeChildren !== null && i < iterType.typeChildren.length) {
						elemType = iterType.typeChildren[i];
					} else if (iterType !== null && (iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray) && iterType.typeReturn !== null) {
						// Array of tuples: element type from tuple children
						const tupleType = iterType.typeReturn;
						if (tupleType !== null && tupleType.kind === TypeKind.Tuple && tupleType.typeChildren !== null && i < tupleType.typeChildren.length) {
							elemType = tupleType.typeChildren[i];
						}
					}
					defineSymbol(ctx.table, makeSymbol(id.name, SymbolKind.Variable, elemType, !isConst));
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
			}
		}
	}
}

function checkForInStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForInStmtData;
	checkExpr(ctx, d.forInObject, null as unknown as Type);
	const saved = enterLoopScope(ctx);
	defineSymbol(ctx.table, makeSymbol(d.forInBinding, SymbolKind.Variable, unknownType(), !d.forInIsConst));
	checkStmt(ctx, d.forInBody);
	exitLoopScope(ctx, saved);
}

function checkDoWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as DoWhileStmtData;
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.doBody);
	exitLoopScope(ctx, saved);
	checkExpr(ctx, d.doCondition, null as unknown as Type);
}

function checkBlock(ctx: CheckerContext, node: Node): void {
	const d = node.data as BlockStmtData;
	openScope(ctx.table, ScopeKind.Block);
	let i = 0;
	while (i < d.statements.length) {
		if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { closeScope(ctx.table); return; }
		const stmt = d.statements[i];
		checkStmt(ctx, stmt);

		// Guard clause narrowing: if (x === null) return; → x is non-null for rest of block
		if (stmt.kind === NodeKind.IfStmt) {
			const guardNarrow = tryGuardClauseNarrow(ctx, stmt);
			if (guardNarrow !== "") {
				const varName = sliceStr(guardNarrow, 1, guardNarrow.length);
				const sym = lookupSymbol(ctx.table, varName);
				if (sym !== null) {
					const saved = sym.symbolType;
					sym.symbolType = removeNullFromType(saved);
					// Check remaining statements with narrowed type
					let j = i + 1;
					while (j < d.statements.length) {
						checkStmt(ctx, d.statements[j]);
						j = j + 1;
					}
					sym.symbolType = saved;
					closeScope(ctx.table);
					return;
				}
			}
		}
		i = i + 1;
	}
	closeScope(ctx.table);
}

function checkReturnStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (ctx.currentFunction === null) {
		addError(ctx, "return outside of function", node.location.line, node.location.column);
	}
	if (d.argument !== null && d.argument.kind !== NodeKind.NullLiteral) {
		// Pass declared return type as expectedType (Implementation parity)
		let returnExpected = null as unknown as Type;
		if (ctx.currentFunction !== null
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
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = retType;
		}
		// Check against declared return type
		if (ctx.currentFunction !== null
			&& ctx.currentFunction.symbolType.kind === TypeKind.Function
			&& ctx.currentFunction.symbolType.typeReturn !== null
			&& ctx.currentFunction.symbolType.typeReturn.kind !== TypeKind.Unknown
			&& retType.kind !== TypeKind.Unknown
			&& retType.kind !== TypeKind.Error) {
			if (!isAssignable(retType, ctx.currentFunction.symbolType.typeReturn)) {
				addError(ctx, "Return type mismatch: cannot assign to declared return type", node.location.line, node.location.column);
			}
		}
	}
}

function checkTryCatch(ctx: CheckerContext, node: Node): void {
	const d = node.data as TryCatchStmtData;
	checkStmt(ctx, d.tryBody);
	if (d.catchBody !== null) {
		openScope(ctx.table, ScopeKind.Block);
		if (d.catchName !== "") {
			defineSymbol(ctx.table, makeSymbol(d.catchName, SymbolKind.Variable, unknownType(), false));
		}
		checkStmt(ctx, d.catchBody);
		closeScope(ctx.table);
	}
	if (d.finallyBody !== null) {
		checkStmt(ctx, d.finallyBody);
	}
}

function checkSwitchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as SwitchStmtData;
	checkExpr(ctx, d.switchDisc, null as unknown as Type);
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		for (const t of cd.caseTests) { checkExpr(ctx, t, null as unknown as Type); }
		for (const s of cd.caseStmts) { checkStmt(ctx, s); }
	}
}

function checkMatchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as MatchStmtData;
	const discType = checkExpr(ctx, d.matchStmtDisc, null as unknown as Type);
	let hasWildcard = false;
	const coveredMembers: string[] = [];
	for (const c of d.matchStmtCases) {
		const cd = c.data as MatchCaseData;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				// Wildcard/binding — Standard reference's else has no pattern nodes at all.
				// We set nodeType for validator; no symbol needed (never referenced).
				hasWildcard = true;
				p.nodeType = discType;
			} else {
				// Extract enum member name before checkExpr (which rewrites MemberExpr → Identifier)
				if (p.kind === NodeKind.MemberExpr) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				// All pattern expressions: semConstExpr + fitNode (reference parity)
				checkExpr(ctx, p, discType);
			}
		}
		checkStmt(ctx, cd.caseBody);
	}
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		checkEnumExhaustiveness(ctx, discType, coveredMembers);
	}
}

// ===== Function Body Checker =====

// Unified function body checker — works for FunctionDecl (resolved param types),
// MethodDecl, ConstructorDecl.
function checkFunctionBody(ctx: CheckerContext, sym: Symbol, params: string[], body: Node): void {
	const savedFunction = ctx.currentFunction;
	ctx.currentFunction = sym;
	openScope(ctx.table, ScopeKind.Function);
	let i = 0;
	for (const param of params) {
		let paramType = unknownType();
		if (sym !== null && sym.symbolType.kind === TypeKind.Function && i < sym.symbolType.typeChildren.length) {
			paramType = sym.symbolType.typeChildren[i];
		}
		const paramSym = makeSymbol(param, SymbolKind.Parameter, paramType, false);
		// Receiver is implicitly LENT (borrowed)
		if (param === "this" || (i === 0 && param === "self")) {
			setFlag(paramSym, SymbolFlag.Lent);
		}
		defineSymbol(ctx.table, paramSym);
		i += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		checkStmt(ctx, body);
	} else {
		// Expression body (arrow functions) — infer return type
		const exprType = checkExpr(ctx, body, null as unknown as Type);
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
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
	checkExpr(ctx, d.destrInit, null as unknown as Type);
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
	collectTopLevel(ctx, program);        // Pass 1: register names
	resolveDeclarations(ctx, program);    // Pass 2: resolve types
	checkProgramBody(ctx, program);       // Pass 3: infer + check
}

// Extract @include/@link/@passC/@passL directives from program AST into context.
function collectDirectives(ctx: CheckerContext, program: Node): void {
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		if (stmt.kind === NodeKind.ExprStmt) {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.MacroInvocation) {
				const mi = d.expr.data as MacroInvocationData;
				if (mi.macroArgs.length > 0 && mi.macroArgs[0].kind === NodeKind.StringLiteral) {
					const sd = mi.macroArgs[0].data as StringLiteralData;
					const name = mi.macroName;
					if (name === "include") {
						if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
						ctx.includeDirectives = ctx.includeDirectives + sd.value;
					} else if (name === "compile") {
						if (ctx.compileDirectives !== "") ctx.compileDirectives = ctx.compileDirectives + "\n";
						ctx.compileDirectives = ctx.compileDirectives + sd.value;
					} else if (name === "link" || name === "passC" || name === "passL") {
						if (ctx.compilerFlags !== "") ctx.compilerFlags = ctx.compilerFlags + " ";
						ctx.compilerFlags = ctx.compilerFlags + sd.value;
					}
				}
			}
		}
	}
}

function defineBuiltinConstants(ctx: CheckerContext): void {
	const nanSym = makeSymbol("NaN", SymbolKind.Variable, numberType(), false);
	nanSym.state = SymbolState.Checked;
	nanSym.builtinKind = "NaN";
	defineSymbol(ctx.table, nanSym);
	const infSym = makeSymbol("Infinity", SymbolKind.Variable, numberType(), false);
	infSym.state = SymbolState.Checked;
	infSym.builtinKind = "Infinity";
	defineSymbol(ctx.table, infSym);
}

// ===== Unified Prelude Loading (reference parity: single pipeline) =====

// Load a single prelude module into a context. Shared by all paths.
function loadPreludeOne(ctx: CheckerContext, specifier: string, stdPath: string): void {
	const base = stdPath.length > 0 ? stdPath + "/" + sliceStr(specifier, 4, specifier.length) : specifier;
	let src = readFile(base + ".ms");
	if (src.length === 0) {
		src = readFile(base + "/index.cms");
	}
	if (src.length === 0) {
		src = readFile(base + "/index.ms");
	}
	if (src.length > 0) {
		const pr = parseSource(src);
		if (pr.ok) {
			runThreePasses(ctx, pr.value);
			collectDirectives(ctx, pr.value);
			const scope = ctx.table.current;
			for (const sym of scope.symbols) {
				ensureShaped(sym, ctx);
				// Also ensure newly added overloads are shaped — if the primary was
				// already shaped by a previous prelude, ensureShaped skips it and
				// its new overloads never get resolved.
				for (const ov of sym.overloads) {
					ensureShaped(ov, ctx);
				}
			}
		} else {
			console.log("[prelude] parse error for " + specifier + ": " + pr.error);
		}
	} else {
		console.log("[prelude] no source found for " + specifier + " (tried " + base + ".ms, " + base + "/index.cms, " + base + "/index.ms)");
	}
}

// Build a prelude context with all globalImports loaded.
// Used by both standalone checkProgram and orchestrator.
export function buildPreludeContext(stdPath: string): CheckerContext {
	const ctx = createContext();
	ctx.extensionRegistry = createExtensionRegistry();
	for (const imp of globalImports()) {
		loadPreludeOne(ctx, imp, stdPath);
	}
	return ctx;
}

// Inject exported prelude symbols, extensions, and directives into a module context.
function injectPrelude(ctx: CheckerContext, preludeCtx: CheckerContext): void {
	for (const sym of preludeCtx.table.current.symbols) {
		if (hasFlag(sym, SymbolFlag.Exported)) {
			ctx.table.current.symbols.push(sym);
		}
	}
	if (preludeCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
		for (const ext of preludeCtx.extensionRegistry.methods) {
			if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
				registerExtension(ctx.extensionRegistry, ext);
			}
		}
	}
	if (preludeCtx.includeDirectives !== "") {
		if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
		ctx.includeDirectives = ctx.includeDirectives + preludeCtx.includeDirectives;
	}
	if (preludeCtx.compileDirectives !== "") {
		if (ctx.compileDirectives !== "") ctx.compileDirectives = ctx.compileDirectives + "\n";
		ctx.compileDirectives = ctx.compileDirectives + preludeCtx.compileDirectives;
	}
	if (preludeCtx.compilerFlags !== "") {
		if (ctx.compilerFlags !== "") ctx.compilerFlags = ctx.compilerFlags + " ";
		ctx.compilerFlags = ctx.compilerFlags + preludeCtx.compilerFlags;
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
	const ctx = mod !== null ? createModuleContext(graph, mod) : createContext();
	ctx.extensionRegistry = createExtensionRegistry();
	if (registry !== null) ctx.exportRegistry = registry;  // override empty default with caller's registry
	if (cancelCtx !== null) { ctx.cancelCtx = cancelCtx; ctx.cancelVersion = cancelVersion; }
	injectPrelude(ctx, preludeCtx);
	const consoleClass = lookupSymbol(ctx.table, "console");
	if (consoleClass !== null) {
		const consoleGlobal = makeSymbol("console", SymbolKind.Variable, consoleClass.symbolType, false);
		defineSymbol(ctx.table, consoleGlobal);
		consoleGlobal.state = SymbolState.Shaped;
	}
	defineBuiltinConstants(ctx);
	openScope(ctx.table, ScopeKind.Module);
	runThreePasses(ctx, program);
	collectDirectives(ctx, program);
	inferOwnership(ctx, program);
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

// Register callback at module load time
registerCheckStmt((ctx: CheckerContext, node: Node): void => { checkStmt(ctx, node); });

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
	assert sym.symbolType.kind === TypeKind.Result;
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

