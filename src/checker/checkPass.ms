import { Node, NodeKind } from "../ast/node";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType,
	voidType, nullType, errorType,
	isNumeric, isStringType, isCallable, getReturnType, getElementType, getProperty,
} from "./types";
import {
	Symbol, SymbolKind, SymbolTable, ScopeKind,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope,
} from "./symbol";
import { CheckerContext, createContext, addError, hasErrors, errorCount } from "./context";
import { collectTopLevel, defineOrError } from "./collectPass";
import { resolveDeclarations } from "./resolvePass";
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
			const d = node.data as { expr: Node };
			checkExpr(ctx, d.expr);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as { throwArg: Node };
			checkExpr(ctx, d.throwArg);
		},
		NodeKind.TryCatchStmt => checkTryCatch(ctx, node),
		NodeKind.SwitchStmt => checkSwitchStmt(ctx, node),
		NodeKind.MatchStmt => checkMatchStmt(ctx, node),
		NodeKind.DeferStmt => {
			const d = node.data as { deferExpr: Node };
			checkExpr(ctx, d.deferExpr);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as { decorators: Node[], decoratedNode: Node };
			checkStmt(ctx, d.decoratedNode);
		},
		NodeKind.DestructuringDecl => checkDestructuringDecl(ctx, node),
		_ => {},
	};
}

// ===== Expression Checker =====

export function checkExpr(ctx: CheckerContext, node: Node): Type {
	return match (node.kind) {
		NodeKind.NumberLiteral | NodeKind.BigIntLiteral => numberType(),
		NodeKind.StringLiteral => stringType(),
		NodeKind.BooleanLiteral => booleanType(),
		NodeKind.NullLiteral => nullType(),
		NodeKind.RegexLiteral | NodeKind.QuoteExpr => unknownType(),
		NodeKind.Identifier => {
			const d = node.data as { name: string };
			const sym = lookupSymbol(ctx.table, d.name);
			if (sym === null) {
				addError(ctx, `Undefined variable '${d.name}'`);
				return errorType();
			}
			sym.symbolType;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as { operator: string, left: Node, right: Node };
			const leftType = checkExpr(ctx, d.left);
			const rightType = checkExpr(ctx, d.right);
			inferBinaryOp(d.operator, leftType, rightType);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as { unaryOp: string, operand: Node };
			checkExpr(ctx, d.operand);
			inferUnaryOp(d.unaryOp);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as { updateOp: string, updateArg: Node, isPrefix: boolean };
			checkExpr(ctx, d.updateArg);
			unknownType();
		},
		NodeKind.CallExpr => {
			const d = node.data as { callee: Node, arguments: Node[] };
			const calleeType = checkExpr(ctx, d.callee);
			for (const arg of d.arguments) {
				checkExpr(ctx, arg);
			}
			getReturnType(calleeType);
		},
		NodeKind.MemberExpr => {
			const d = node.data as { object: Node, property: string };
			const objType = checkExpr(ctx, d.object);
			getProperty(objType, d.property);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as { array: Node, index: Node };
			const arrType = checkExpr(ctx, d.array);
			checkExpr(ctx, d.index);
			getElementType(arrType);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as { properties: Node[], keys: string[] };
			for (const prop of d.properties) {
				checkExpr(ctx, prop);
			}
			unknownType();
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as { elements: Node[] };
			for (const el of d.elements) {
				checkExpr(ctx, el);
			}
			unknownType();
		},
		NodeKind.ArrowFunction => { checkArrowFunction(ctx, node); unknownType(); },
		NodeKind.FunctionExpr => { checkFunctionExpr(ctx, node); unknownType(); },
		NodeKind.ConditionalExpr => {
			const d = node.data as { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node };
			checkExpr(ctx, d.ternaryCondition);
			checkExpr(ctx, d.ternaryConsequent);
			checkExpr(ctx, d.ternaryAlternate);
			unknownType();
		},
		NodeKind.TypeAssertion => {
			const d = node.data as { asExpr: Node };
			checkExpr(ctx, d.asExpr);
			unknownType();
		},
		NodeKind.SpreadExpr => {
			const d = node.data as { spreadArg: Node };
			checkExpr(ctx, d.spreadArg);
			unknownType();
		},
		NodeKind.NewExpr => {
			const d = node.data as { newCallee: Node, newArguments: Node[] };
			checkExpr(ctx, d.newCallee);
			for (const arg of d.newArguments) {
				checkExpr(ctx, arg);
			}
			unknownType();
		},
		NodeKind.TryExpr => {
			const d = node.data as { tryArg: Node, hasCatch: boolean, catchVal: Node };
			checkExpr(ctx, d.tryArg);
			unknownType();
		},
		NodeKind.MatchExpr => { checkMatchExpr(ctx, node); unknownType(); },
		NodeKind.AwaitExpr => {
			const d = node.data as { awaitArg: Node };
			checkExpr(ctx, d.awaitArg);
			unknownType();
		},
		NodeKind.YieldExpr => {
			const d = node.data as { yieldArg: Node, isDelegate: boolean };
			checkExpr(ctx, d.yieldArg);
			unknownType();
		},
		NodeKind.MoveExpr => {
			const d = node.data as { moveArg: Node };
			checkExpr(ctx, d.moveArg);
			unknownType();
		},
		NodeKind.OutExpr => {
			const d = node.data as { outArg: Node };
			checkExpr(ctx, d.outArg);
			unknownType();
		},
		_ => unknownType(),
	};
}

// ===== Operator Inference =====

function inferBinaryOp(op: string, leftType: Type, rightType: Type): Type {
	return match (op) {
		// Comparison operators always return boolean
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" => booleanType(),
		// Logical operators return left operand type (short-circuit)
		"&&" | "||" => leftType,
		// String concatenation: + with either string → string
		"+" => {
			if (isStringType(leftType) || isStringType(rightType)) return stringType();
			if (isNumeric(leftType) && isNumeric(rightType)) return numberType();
			unknownType();
		},
		// Arithmetic operators → number
		"-" | "*" | "/" | "%" | "**" => numberType(),
		// Bitwise operators → number
		"&" | "|" | "^" | "<<" | ">>" | ">>>" => numberType(),
		// Nullish coalescing returns left type
		"??" => leftType,
		_ => unknownType(),
	};
}

function inferUnaryOp(op: string): Type {
	return match (op) {
		"!" => booleanType(),
		"-" | "+" | "~" => numberType(),
		"typeof" => stringType(),
		_ => unknownType(),
	};
}

// ===== Statement Helpers =====

function checkVariableDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as { declName: string, initializer: Node, isConst: boolean };
	const initType = checkExpr(ctx, d.initializer);
	defineOrError(ctx, makeSymbol(d.declName, SymbolKind.Variable, initType, !d.isConst), node);
}

function checkFunctionDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as { fnName: string, params: string[], fnBody: Node, fnFlags: string };
	const savedFunction = ctx.currentFunction;
	ctx.currentFunction = lookupSymbol(ctx.table, d.fnName);
	openScope(ctx.table, ScopeKind.Function);
	for (const param of d.params) {
		defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, unknownType(), false));
	}
	checkStmt(ctx, d.fnBody);
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
}

function checkClassDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as { className: string, classExtends: string, classBody: Node[] };
	openScope(ctx.table, ScopeKind.Class);
	for (const member of d.classBody) {
		checkClassMember(ctx, member);
	}
	closeScope(ctx.table);
}

function checkClassMember(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.PropertyDecl => {},
		NodeKind.MethodDecl => {
			const d = node.data as { methodName: string, methodParams: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string };
			const savedFunction = ctx.currentFunction;
			ctx.currentFunction = makeSymbol(d.methodName, SymbolKind.Method, unknownType(), false);
			openScope(ctx.table, ScopeKind.Function);
			for (const param of d.methodParams) {
				defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, unknownType(), false));
			}
			checkStmt(ctx, d.methodBody);
			closeScope(ctx.table);
			ctx.currentFunction = savedFunction;
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as { ctorParams: string[], ctorBody: Node };
			const savedFunction = ctx.currentFunction;
			ctx.currentFunction = makeSymbol("constructor", SymbolKind.Method, unknownType(), false);
			openScope(ctx.table, ScopeKind.Function);
			for (const param of d.ctorParams) {
				defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, unknownType(), false));
			}
			checkStmt(ctx, d.ctorBody);
			closeScope(ctx.table);
			ctx.currentFunction = savedFunction;
		},
		_ => {},
	};
}

function checkExportDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as { exportedDecl: Node };
	if (d.exportedDecl.kind === NodeKind.VariableDecl) {
		checkVariableDecl(ctx, d.exportedDecl);
		return;
	}
	checkStmt(ctx, d.exportedDecl);
}

function checkIfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { condition: Node, consequent: Node, alternate: Node };
	checkExpr(ctx, d.condition);
	checkStmt(ctx, d.consequent);
	if (d.alternate !== null && d.alternate.kind !== NodeKind.NullLiteral) {
		checkStmt(ctx, d.alternate);
	}
}

function checkWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { whileCondition: Node, whileBody: Node };
	checkExpr(ctx, d.whileCondition);
	const savedLoop = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	checkStmt(ctx, d.whileBody);
	closeScope(ctx.table);
	ctx.inLoop = savedLoop;
}

function checkForStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node };
	const savedLoop = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	checkStmt(ctx, d.forInit);
	checkExpr(ctx, d.forCondition);
	checkExpr(ctx, d.forUpdate);
	checkStmt(ctx, d.forBody);
	closeScope(ctx.table);
	ctx.inLoop = savedLoop;
}

function checkForOfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node };
	checkExpr(ctx, d.forOfIterable);
	const savedLoop = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	defineSymbol(ctx.table, makeSymbol(d.forOfBinding, SymbolKind.Variable, unknownType(), !d.forOfIsConst));
	checkStmt(ctx, d.forOfBody);
	closeScope(ctx.table);
	ctx.inLoop = savedLoop;
}

function checkForInStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { forInBinding: string, forInIsConst: boolean, forInObject: Node, forInBody: Node };
	checkExpr(ctx, d.forInObject);
	const savedLoop = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	defineSymbol(ctx.table, makeSymbol(d.forInBinding, SymbolKind.Variable, unknownType(), !d.forInIsConst));
	checkStmt(ctx, d.forInBody);
	closeScope(ctx.table);
	ctx.inLoop = savedLoop;
}

function checkDoWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { doBody: Node, doCondition: Node };
	const savedLoop = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	checkStmt(ctx, d.doBody);
	closeScope(ctx.table);
	ctx.inLoop = savedLoop;
	checkExpr(ctx, d.doCondition);
}

function checkBlock(ctx: CheckerContext, node: Node): void {
	const d = node.data as { statements: Node[] };
	openScope(ctx.table, ScopeKind.Block);
	for (const stmt of d.statements) {
		checkStmt(ctx, stmt);
	}
	closeScope(ctx.table);
}

function checkReturnStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { argument: Node };
	if (ctx.currentFunction === null) {
		addError(ctx, "return outside of function");
	}
	if (d.argument !== null && d.argument.kind !== NodeKind.NullLiteral) {
		checkExpr(ctx, d.argument);
	}
}

function checkTryCatch(ctx: CheckerContext, node: Node): void {
	const d = node.data as { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node };
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
	const d = node.data as { switchDisc: Node, switchCases: Node[] };
	checkExpr(ctx, d.switchDisc);
	for (const c of d.switchCases) {
		const cd = c.data as { caseTests: Node[], caseStmts: Node[], isDefault: boolean };
		for (const t of cd.caseTests) { checkExpr(ctx, t); }
		for (const s of cd.caseStmts) { checkStmt(ctx, s); }
	}
}

function checkMatchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as { matchStmtDisc: Node, matchStmtCases: Node[] };
	checkExpr(ctx, d.matchStmtDisc);
	for (const c of d.matchStmtCases) {
		const cd = c.data as { casePatterns: Node[], caseBody: Node };
		checkStmt(ctx, cd.caseBody);
	}
}

function checkMatchExpr(ctx: CheckerContext, node: Node): void {
	const d = node.data as { matchDisc: Node, matchCases: Node[] };
	checkExpr(ctx, d.matchDisc);
	for (const c of d.matchCases) {
		const cd = c.data as { casePatterns: Node[], caseBody: Node };
		checkExpr(ctx, cd.caseBody);
	}
}

function checkArrowFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as { arrowParams: string[], arrowBody: Node, arrowFlags: string };
	const savedFunction = ctx.currentFunction;
	ctx.currentFunction = makeSymbol("(arrow)", SymbolKind.Function, unknownType(), false);
	openScope(ctx.table, ScopeKind.Function);
	for (const param of d.arrowParams) {
		defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, unknownType(), false));
	}
	if (d.arrowBody.kind === NodeKind.BlockStmt) {
		checkStmt(ctx, d.arrowBody);
	} else {
		checkExpr(ctx, d.arrowBody);
	}
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
}

function checkFunctionExpr(ctx: CheckerContext, node: Node): void {
	const d = node.data as { funcExprParams: string[], funcExprBody: Node, funcExprFlags: string };
	const savedFunction = ctx.currentFunction;
	ctx.currentFunction = makeSymbol("(anon)", SymbolKind.Function, unknownType(), false);
	openScope(ctx.table, ScopeKind.Function);
	for (const param of d.funcExprParams) {
		defineSymbol(ctx.table, makeSymbol(param, SymbolKind.Parameter, unknownType(), false));
	}
	checkStmt(ctx, d.funcExprBody);
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
}

function checkDestructuringDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as { destrPattern: Node, destrInit: Node, destrIsConst: boolean };
	checkExpr(ctx, d.destrInit);
}

// ===== Check Program Body =====

export function checkProgramBody(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as { programStmts: Node[] };
	for (const stmt of stmts.programStmts) {
		checkStmt(ctx, stmt);
	}
}

// ===== Main Entry Point =====

export function checkProgram(program: Node): CheckerContext {
	const ctx = createContext();
	collectTopLevel(ctx, program);        // Pass 1: register names
	resolveDeclarations(ctx, program);    // Pass 2: resolve types
	checkProgramBody(ctx, program);       // Pass 3: infer + check
	return ctx;
}

// ===== Tests =====

import { parseSource } from "../parser/statements/util";

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
		// foo's return type is unknown (no annotation), so call returns unknown
		check(sym.symbolType.kind === TypeKind.Unknown);
	});
	test("forward reference to function is callable", () => {
		const ctx = checkSource("const x = foo(1); function foo(a) { return 1; }");
		check(!hasErrors(ctx));
	});
});
