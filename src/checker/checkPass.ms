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
	DestructuringDeclData, ProgramData,
} from "../ast/node";
import {
	Type, TypeKind,
	unknownType, nullType, stringType,
	createUnion,
} from "./types";
import {
	Symbol, SymbolKind, ScopeKind,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope,
} from "./symbol";
import { CheckerContext, createContext, addError, hasErrors, errorCount } from "./context";
import { collectTopLevel, defineOrError } from "./collectPass";
import { readFile } from "std/process";
import { globalImports } from "./prelude";
import { isAssignable } from "./compat";
import { resolveDeclarations, resolveAnnotation } from "./resolvePass";
import { sliceStr } from "../utils/string";
import { checkExpr, checkEnumExhaustiveness } from "./checkExprPass";
import { registerCheckStmt } from "./checkerCallbacks";
import { parseSource } from "../parser/statements/validation";
import { test, check, testGroup } from "std/testing";

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
		NodeKind.BreakStmt => { if (!ctx.inLoop) { addError(ctx, "break outside of loop"); } },
		NodeKind.ContinueStmt => { if (!ctx.inLoop) { addError(ctx, "continue outside of loop"); } },
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			checkExpr(ctx, d.expr);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			checkExpr(ctx, d.throwArg);
		},
		NodeKind.TryCatchStmt => checkTryCatch(ctx, node),
		NodeKind.SwitchStmt => checkSwitchStmt(ctx, node),
		NodeKind.MatchStmt => checkMatchStmt(ctx, node),
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			checkExpr(ctx, d.deferExpr);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			checkStmt(ctx, d.decoratedNode);
		},
		NodeKind.DestructuringDecl => checkDestructuringDecl(ctx, node),
		_ => {},
	};
}

// ===== Statement Helpers =====

function checkVariableDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	const initType = checkExpr(ctx, d.initializer);
	// Prefer explicit type annotation over inferred type
	let varType = initType;
	if (d.declType !== "") {
		varType = resolveAnnotation(d.declType, ctx);
	}
	defineOrError(ctx, makeSymbol(d.declName, SymbolKind.Variable, varType, d.declKind !== DeclKind.Const), node);
}

function checkFunctionDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = lookupSymbol(ctx.table, d.fnName);

	// Save/restore inferredReturn for nested functions
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = unknownType();

	checkFunctionBody(ctx, sym, d.params, d.fnBody);

	// If return type was unknown (no annotation), use inferred type
	if (sym !== null && sym.symbolType.kind === TypeKind.Function
		&& sym.symbolType.typeReturn !== null
		&& sym.symbolType.typeReturn.kind === TypeKind.Unknown
		&& ctx.inferredReturn.kind !== TypeKind.Unknown) {
		sym.symbolType.typeReturn = ctx.inferredReturn;
	}

	ctx.inferredReturn = savedReturn;
}

function checkClassDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	openScope(ctx.table, ScopeKind.Class);
	for (const member of d.classBody) {
		checkClassMember(ctx, member);
	}
	closeScope(ctx.table);
}

function checkClassMember(ctx: CheckerContext, node: Node): void {
	// DecoratedDecl wrapping a class member — unwrap and check the inner node
	if (node.kind === NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		checkClassMember(ctx, dd.decoratedNode);
		return;
	}
	match (node.kind) {
		NodeKind.PropertyDecl => {},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			checkFunctionBody(ctx, makeSymbol(d.methodName, SymbolKind.Method, unknownType(), false), d.methodParams, d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			checkFunctionBody(ctx, makeSymbol("constructor", SymbolKind.Method, unknownType(), false), d.ctorParams, d.ctorBody);
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
function analyzeNullCheck(condition: Node): string {
	if (condition.kind !== NodeKind.BinaryExpr) return "";
	const d = condition.data as BinaryExprData;
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

function checkIfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as IfStmtData;
	checkExpr(ctx, d.condition);

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
	checkExpr(ctx, d.whileCondition);
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.whileBody);
	exitLoopScope(ctx, saved);
}

function checkForStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForStmtData;
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.forInit);
	checkExpr(ctx, d.forCondition);
	checkExpr(ctx, d.forUpdate);
	checkStmt(ctx, d.forBody);
	exitLoopScope(ctx, saved);
}

function checkForOfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForOfStmtData;
	checkExpr(ctx, d.forOfIterable);
	const saved = enterLoopScope(ctx);
	defineSymbol(ctx.table, makeSymbol(d.forOfBinding, SymbolKind.Variable, unknownType(), !d.forOfIsConst));
	checkStmt(ctx, d.forOfBody);
	exitLoopScope(ctx, saved);
}

function checkForInStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForInStmtData;
	checkExpr(ctx, d.forInObject);
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
	checkExpr(ctx, d.doCondition);
}

function checkBlock(ctx: CheckerContext, node: Node): void {
	const d = node.data as BlockStmtData;
	openScope(ctx.table, ScopeKind.Block);
	for (const stmt of d.statements) {
		checkStmt(ctx, stmt);
	}
	closeScope(ctx.table);
}

function checkReturnStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (ctx.currentFunction === null) {
		addError(ctx, "return outside of function");
	}
	if (d.argument !== null && d.argument.kind !== NodeKind.NullLiteral) {
		const retType = checkExpr(ctx, d.argument);
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
				addError(ctx, "Return type mismatch: cannot assign to declared return type");
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
	checkExpr(ctx, d.switchDisc);
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		for (const t of cd.caseTests) { checkExpr(ctx, t); }
		for (const s of cd.caseStmts) { checkStmt(ctx, s); }
	}
}

function checkMatchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as MatchStmtData;
	const discType = checkExpr(ctx, d.matchStmtDisc);
	let hasWildcard = false;
	const coveredMembers: string[] = [];
	for (const c of d.matchStmtCases) {
		const cd = c.data as MatchCaseData;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) { hasWildcard = true; }
			if (p.kind === NodeKind.MemberExpr) {
				const pmd = p.data as MemberExprData;
				coveredMembers.push(pmd.property);
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
		defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, paramType, false));
		i += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		checkStmt(ctx, body);
	} else {
		// Expression body (arrow functions) — infer return type
		const exprType = checkExpr(ctx, body);
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
	checkExpr(ctx, d.destrInit);
}

// ===== Check Program Body =====

export function checkProgramBody(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
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

export function checkProgram(program: Node): CheckerContext {
	const ctx = createContext();
	// Parse + check global imports in Global scope
	for (const imp of globalImports()) {
		const src = readFile(imp);
		if (src.length > 0) {
			const pr = parseSource(src);
			if (pr.ok) {
				runThreePasses(ctx, pr.value);
			}
		}
	}
	// User code in Module scope
	openScope(ctx.table, ScopeKind.Module);
	runThreePasses(ctx, program);
	return ctx;
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

testGroup("Checker Scope", () => {
	test("variable decl", () => {
		check(checkOk("const x = 1;"));
		check(checkOk("let y = 2;"));
		check(checkOk("var z = 3;"));
	});
	test("variable use", () => {
		check(checkOk("const x = 1; const y = x;"));
	});
	test("undefined variable", () => {
		check(!checkOk("const x = y;"));
		check(checkErrors("const x = y;") === 1);
	});
	test("function scope", () => {
		check(checkOk("function foo(a, b) { const x = a; }"));
	});
	test("forward reference", () => {
		check(checkOk("const x = foo; function foo() { return 1; }"));
	});
	test("block scope", () => {
		check(checkOk("const x = 1; if (true) { const y = x; }"));
	});
	test("nested scope isolation", () => {
		check(!checkOk("if (true) { const y = 1; } const z = y;"));
	});
});

testGroup("Checker Loops", () => {
	test("break in loop", () => {
		check(checkOk("while (true) { break; }"));
	});
	test("break outside loop", () => {
		check(!checkOk("break;"));
	});
	test("continue in loop", () => {
		check(checkOk("for (let i = 0; i < 10; i++) { continue; }"));
	});
	test("continue outside loop", () => {
		check(!checkOk("continue;"));
	});
	test("for-of binding", () => {
		check(checkOk("const items = 1; for (const item of items) { const x = item; }"));
	});
});

testGroup("Checker Functions", () => {
	test("return in function", () => {
		check(checkOk("function foo() { return 1; }"));
	});
	test("return outside function", () => {
		check(!checkOk("return 1;"));
	});
	test("class method scope", () => {
		check(checkOk("class Foo { bar(x) { return x; } }"));
	});
	test("try-catch param", () => {
		check(checkOk("try { const x = 1; } catch (e) { const y = e; }"));
	});
	test("arrow function", () => {
		check(checkOk("const f = (x) => x;"));
	});
});

testGroup("Checker Literals", () => {
	test("number type", () => {
		const ctx = checkSource("const x = 42;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("string type", () => {
		const ctx = checkSource("const s = \"hello\";");
		const sym = lookupSymbol(ctx.table, "s");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
	test("boolean type", () => {
		const ctx = checkSource("const b = true;");
		const sym = lookupSymbol(ctx.table, "b");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Boolean);
	});
	test("null type", () => {
		const ctx = checkSource("const n = null;");
		const sym = lookupSymbol(ctx.table, "n");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Null);
	});
});

testGroup("Checker Operators", () => {
	test("arithmetic returns number", () => {
		const ctx = checkSource("const x = 1 + 2;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("string concat returns string", () => {
		const ctx = checkSource("const x = \"a\" + \"b\";");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
	test("comparison returns boolean", () => {
		const ctx = checkSource("const x = 1 < 2;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Boolean);
	});
	test("equality returns boolean", () => {
		const ctx = checkSource("const x = 1 === 2;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Boolean);
	});
	test("negation returns boolean", () => {
		const ctx = checkSource("const x = !true;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Boolean);
	});
	test("unary minus returns number", () => {
		const ctx = checkSource("const x = -5;");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
});

testGroup("Checker 3-Pass", () => {
	test("function has Function type after resolve", () => {
		const ctx = checkSource("function foo(a, b) { return 1; }");
		const sym = lookupSymbol(ctx.table, "foo");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren.length === 2);
		check(sym.symbolType.typeNames.length === 2);
	});
	test("call returns function return type", () => {
		const ctx = checkSource("function foo(a, b) { return 1; } const x = foo(1, 2);");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		// foo's return type inferred as number from body
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("forward reference to function is callable", () => {
		const ctx = checkSource("const x = foo(1); function foo(a) { return 1; }");
		check(!hasErrors(ctx));
	});
	test("typed function params resolved", () => {
		const ctx = checkSource("function add(a: number, b: number): number { return a; }");
		const sym = lookupSymbol(ctx.table, "add");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren[0].kind === TypeKind.Number);
		check(sym.symbolType.typeChildren[1].kind === TypeKind.Number);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
	test("typed function call returns annotated type", () => {
		const ctx = checkSource("function greet(name: string): string { return name; } const x = greet(\"hi\");");
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
	test("array literal infers element type", () => {
		const ctx = checkSource("const arr = [1, 2, 3];");
		const sym = lookupSymbol(ctx.table, "arr");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Array);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
	test("arrow function has Function type", () => {
		const ctx = checkSource("const f = (x) => x;");
		const sym = lookupSymbol(ctx.table, "f");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
	});
});

testGroup("Checker Return Inference", () => {
	test("inferred return type from body", () => {
		const ctx = checkSource("function foo() { return 42; }");
		const sym = lookupSymbol(ctx.table, "foo");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
	test("annotated return type preserved", () => {
		const ctx = checkSource("function bar(): string { return \"hi\"; }");
		const sym = lookupSymbol(ctx.table, "bar");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.String);
	});
	test("arrow infers return type", () => {
		const ctx = checkSource("const f = (x) => 42;");
		const sym = lookupSymbol(ctx.table, "f");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.Number);
	});
	test("string return inferred", () => {
		const ctx = checkSource("function greet() { return \"hello\"; }");
		const sym = lookupSymbol(ctx.table, "greet");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.String);
	});
	test("boolean return inferred", () => {
		const ctx = checkSource("function isOk() { return true; }");
		const sym = lookupSymbol(ctx.table, "isOk");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.Boolean);
	});
	test("no return stays unknown", () => {
		const ctx = checkSource("function noop() { const x = 1; }");
		const sym = lookupSymbol(ctx.table, "noop");
		check(sym !== null);
		check(sym.symbolType.typeReturn.kind === TypeKind.Unknown);
	});
});

testGroup("Checker Type Enforcement", () => {
	test("return type mismatch detected", () => {
		check(!checkOk("function foo(): number { return \"hello\"; }"));
	});
	test("return type match ok", () => {
		check(checkOk("function foo(): number { return 42; }"));
	});
	test("return string match ok", () => {
		check(checkOk("function bar(): string { return \"hi\"; }"));
	});
	test("arg type mismatch detected", () => {
		check(!checkOk("function add(a: number, b: number): number { return a; } const x = add(\"hi\", 2);"));
	});
	test("arg type match ok", () => {
		check(checkOk("function add(a: number, b: number): number { return a; } const x = add(1, 2);"));
	});
	test("numeric widening ok", () => {
		check(checkOk("function f(n: number): number { return n; } const x = f(42);"));
	});
});

testGroup("Checker Overloads", () => {
	test("two overloads no error", () => {
		check(checkOk("function add(a: number, b: number): number { return a; } function add(a: string, b: string): string { return a; }"));
	});
	test("overload different arity no error", () => {
		check(checkOk("function f(a: number): number { return a; } function f(a: number, b: number): number { return a; }"));
	});
	test("overload call resolves", () => {
		const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const x = f(1);");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("overload call picks string version", () => {
		const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const y = f(\"hi\");");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "y");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
});

testGroup("Checker Extensions", () => {
	test("extension method registered", () => {
		const ctx = checkSource("function trim(this s: string): string { return s; }");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "trim");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
	});
	test("extension method callable as function", () => {
		const ctx = checkSource("function double(this n: number): number { return n; } const x = double(1);");
		check(!hasErrors(ctx));
	});
	test("extension on builtin type no error", () => {
		check(checkOk("function len(this s: string): number { return 0; }"));
	});
});

testGroup("Checker Generics", () => {
	test("generic function parses ok", () => {
		check(checkOk("function wrap<T>(x: T): T { return x; }"));
	});
	test("generic param resolved as GenericParam", () => {
		const ctx = checkSource("function id<T>(x: T): T { return x; }");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "id");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Function);
		check(sym.symbolType.typeChildren[0].kind === TypeKind.GenericParam);
		check(sym.symbolType.typeReturn.kind === TypeKind.GenericParam);
	});
	test("generic call infers return type", () => {
		const ctx = checkSource("function id<T>(x: T): T { return x; } const n = id(42);");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "n");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("two generic params", () => {
		const ctx = checkSource("function first<T, U>(a: T, b: U): T { return a; } const x = first(1, \"hi\");");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("generic with annotated return", () => {
		check(checkOk("function identity<T>(x: T): T { return x; }"));
	});
});

testGroup("Match Exhaustiveness", () => {
	test("wildcard always exhaustive", () => {
		check(checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { _ => 0 }; }"));
	});
	test("all members covered", () => {
		check(checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2, Color.Blue => 3 }; }"));
	});
	test("missing member errors", () => {
		check(!checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2 }; }"));
	});
	test("binding acts as wildcard", () => {
		check(checkOk("enum Color { Red, Green } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, other => 0 }; }"));
	});
	test("non-enum no exhaustiveness check", () => {
		check(checkOk("const x = match (42) { 1 => \"one\", _ => \"other\" };"));
	});
	test("match expr returns arm type", () => {
		const ctx = checkSource("const x = match (1) { 1 => 42, _ => 0 };");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
});

testGroup("Null Narrowing", () => {
	test("basic not-null check", () => {
		check(checkOk("const x = 1; if (x !== null) { const y = x; }"));
	});
	test("reversed null check", () => {
		check(checkOk("const x = 1; if (null !== x) { const y = x; }"));
	});
	test("equals null narrows", () => {
		check(checkOk("const x = 1; if (x === null) { const y = x; }"));
	});
	test("no narrowing without null check", () => {
		check(checkOk("const x = 1; if (x === x) { const y = x; }"));
	});
	test("removeNullFromType unit", () => {
		const unionType = createUnion([stringType(), nullType()]);
		const narrowed = removeNullFromType(unionType);
		check(narrowed.kind === TypeKind.String);
	});
});

testGroup("Resolve Coverage", () => {
	test("type alias resolves to type", () => {
		const ctx = checkSource("type ID = number;");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "ID");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Number);
	});
	test("type alias Result resolved", () => {
		const ctx = checkSource("type MyResult = Result<number, string>;");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "MyResult");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Result);
	});
	test("distinct type creates Distinct wrapper", () => {
		const ctx = checkSource("distinct type UserId = number;");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "UserId");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Distinct);
	});
	test("variable annotation overrides inference", () => {
		const ctx = checkSource("const x: string = \"hello\";");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "x");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.String);
	});
	test("class property type resolved", () => {
		const ctx = checkSource("class Point { x: number; y: string; getX() { return 1; } }");
		check(!hasErrors(ctx));
		const sym = lookupSymbol(ctx.table, "Point");
		check(sym !== null);
		check(sym.symbolType.kind === TypeKind.Object);
	});
});
