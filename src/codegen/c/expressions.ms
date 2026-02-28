// C Codegen — Expression Emission
//
// genExpr returns a C code snippet string for any expression node.
// genExprToLoc fills a CLoc dest (for statement-level assignment).
//
// Follows Nim's ccgexprs.nim dest carrier pattern, adapted for
// MetaScript value-type interfaces (CLoc passed by value → use return).

import {
	Node, NodeKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData,
	MemberExprData, ArrayAccessData,
	ConditionalExprData, TypeAssertionData, CallExprData,
	ObjectLiteralData, ArrayLiteralData,
	UpdateExprData, NewExprData, MoveExprData, SpreadExprData,
	ExprStmtData,
} from "../../ast/node";
import { Type, TypeKind, getProperty } from "../../checker/types";
import { lookupSymbol, SymbolKind } from "../../checker/symbol";
import {
	CGen, CProc, CLoc, CLocKind, CStorageLoc, Builder, CSection,
	initLoc, noLoc, rdLoc,
	add, addLine, sec,
	pStmts, getTemp, nameSetHas,
} from "./context";
import { mangle, mangleFieldName, safeName } from "./names";
import { formatCNumber, cBoolLiteral, cNullLiteral, cStringLiteral } from "./literals";
import { test, check, testGroup } from "std/testing";

// ===== genExpr — returns C snippet for any expression =====

export function genExpr(g: CGen, p: CProc, node: Node): string {
	if (node === null) return "NIM_NIL";

	return match (node.kind) {
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			formatCNumber(d.value);
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			cStringLiteral(d.value);
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			cBoolLiteral(d.boolValue);
		},
		NodeKind.NullLiteral => {
			cNullLiteral();
		},
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			safeName(d.name);
		},
		NodeKind.BinaryExpr => {
			genBinaryExpr(g, p, node);
		},
		NodeKind.UnaryExpr => {
			genUnaryExpr(g, p, node);
		},
		NodeKind.MemberExpr => {
			genMemberExpr(g, p, node);
		},
		NodeKind.ArrayAccess => {
			genArrayAccess(g, p, node);
		},
		NodeKind.ConditionalExpr => {
			genConditionalExpr(g, p, node);
		},
		NodeKind.TypeAssertion => {
			genTypeAssertion(g, p, node);
		},
		NodeKind.CallExpr => {
			genCallExpr(g, p, node);
		},
		NodeKind.ObjectLiteral => {
			genObjectLiteral(g, p, node);
		},
		NodeKind.ArrayLiteral => {
			genArrayLiteral(g, p, node);
		},
		NodeKind.ArrowFunction => {
			genArrowFunction(g, p, node);
		},
		NodeKind.UpdateExpr => {
			genUpdateExpr(g, p, node);
		},
		NodeKind.NewExpr => {
			genNewExpr(g, p, node);
		},
		NodeKind.MoveExpr => {
			genMoveExpr(g, p, node);
		},
		NodeKind.SpreadExpr => {
			genSpreadExpr(g, p, node);
		},
		NodeKind.FunctionExpr => {
			genFunctionExpr(g, p, node);
		},
		NodeKind.HiddenDeref => {
			genHiddenDeref(g, p, node);
		},
		_ => "/* unsupported expr */0",
	};
}

// ===== genExprAssign — evaluate expression and assign to dest =====
// For statement-level: `dest = expr;`

export function genExprAssign(g: CGen, p: CProc, node: Node, destSnippet: string): void {
	const snippet = genExpr(g, p, node);
	addLine(pStmts(p), destSnippet + " = " + snippet + ";");
}

// ===== Binary Expression =====

function genBinaryExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as BinaryExprData;
	const left = genExpr(g, p, d.left);
	const right = genExpr(g, p, d.right);
	const cOp = mapBinaryOp(d.operator);
	return "(" + left + " " + cOp + " " + right + ")";
}

function mapBinaryOp(op: string): string {
	return match (op) {
		"===" | "==" => "==",
		"!==" | "!=" => "!=",
		"&&" => "&&",
		"||" => "||",
		_ => op,
	};
}

// ===== Unary Expression =====

function genUnaryExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as UnaryExprData;
	const operand = genExpr(g, p, d.operand);
	return "(" + d.unaryOp + operand + ")";
}

// ===== Hidden Deref (compiler-inserted pointer dereference) =====

function genHiddenDeref(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ExprStmtData;
	const inner = genExpr(g, p, d.expr);
	return "(*" + inner + ")";
}

// ===== Member Expression =====

function genMemberExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as MemberExprData;
	const obj = genExpr(g, p, d.object);
	const field = mangleFieldName(d.property);
	return obj + "." + field;
}

// ===== Array Access =====

function genArrayAccess(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ArrayAccessData;
	const arr = genExpr(g, p, d.array);
	const idx = genExpr(g, p, d.index);
	return arr + "[" + idx + "]";
}

// ===== Conditional Expression =====

function genConditionalExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ConditionalExprData;
	const cond = genExpr(g, p, d.ternaryCondition);
	const cons = genExpr(g, p, d.ternaryConsequent);
	const alt = genExpr(g, p, d.ternaryAlternate);
	return "(" + cond + " ? " + cons + " : " + alt + ")";
}

// ===== Type Assertion (as cast) =====

function genTypeAssertion(g: CGen, p: CProc, node: Node): string {
	const d = node.data as TypeAssertionData;
	const expr = genExpr(g, p, d.asExpr);
	const targetType = mangle(d.asType);
	return "((" + targetType + ")" + expr + ")";
}

// ===== Call Expression =====
// Detects closure calls vs direct calls using fnDeclNames from closureCallMarker.
// Direct call: foo(args)
// Closure call: MS_CLOSURE_CALL(closureVar, args) or closureVar.fn(closureVar.env, args)

function genCallExpr(g: CGen, p: CProc, node: Node): string {
	const cd = node.data as CallExprData;
	let isDirect = false;

	// If no fnDeclNames were collected (no closure marker pass), treat all as direct
	if (g.fnDeclNames.names.length === 0) isDirect = true;

	// Check if callee is a known direct function (not a closure)
	if (cd.callee.kind === NodeKind.Identifier) {
		const id = cd.callee.data as IdentifierData;
		if (nameSetHas(g.fnDeclNames, id.name)) isDirect = true;

		// @runtime("c_name") on top-level function — emit C name directly (Nim sfImportc)
		if (g.checkerCtx !== null) {
			const sym = lookupSymbol(g.checkerCtx.table, id.name);
			if (sym !== null && sym.runtimeName !== "") {
				let args = "";
				let i = 0;
				while (i < cd.arguments.length) {
					if (i > 0) args = args + ", ";
					args = args + genExpr(g, p, cd.arguments[i]);
					i += 1;
				}
				return sym.runtimeName + "(" + args + ")";
			}
		}
	}

	// Class method call: console.log(x) → ms_println(x)
	// Unwrap HiddenDeref: checker inserts HiddenDeref for class member access (pointer types)
	if (cd.callee.kind === NodeKind.MemberExpr && g.checkerCtx !== null) {
		const me = cd.callee.data as MemberExprData;
		let calleeObj = me.object;
		if (calleeObj.kind === NodeKind.HiddenDeref) {
			const hd = calleeObj.data as ExprStmtData;
			calleeObj = hd.expr;
		}
		if (calleeObj.kind === NodeKind.Identifier) {
			const objId = calleeObj.data as IdentifierData;
			const objSym = lookupSymbol(g.checkerCtx.table, objId.name);
			if (objSym !== null && objSym.symbolKind === SymbolKind.Class) {
				const methodType = getProperty(objSym.symbolType, me.property);
				if (methodType.typeName !== "") {
					let args = "";
					let i = 0;
					while (i < cd.arguments.length) {
						if (i > 0) args = args + ", ";
						args = args + genExpr(g, p, cd.arguments[i]);
						i += 1;
					}
					return methodType.typeName + "(" + args + ")";
				}
			}
		}
	}

	// MemberExpr callee is always a direct call (method/field access)
	if (cd.callee.kind === NodeKind.MemberExpr) isDirect = true;

	const callee = genExpr(g, p, cd.callee);

	if (isDirect) {
		// Direct function call: callee(args)
		let args = "";
		let i = 0;
		while (i < cd.arguments.length) {
			if (i > 0) args = args + ", ";
			args = args + genExpr(g, p, cd.arguments[i]);
			i += 1;
		}
		return callee + "(" + args + ")";
	}

	// Closure call: callee.fn(callee.env, args...)
	let args = callee + ".env";
	let i = 0;
	while (i < cd.arguments.length) {
		args = args + ", ";
		args = args + genExpr(g, p, cd.arguments[i]);
		i += 1;
	}
	return "((" + callee + ").fn(" + args + "))";
}

// ===== Object Literal =====
// Two cases:
// 1. Closure pair: { fn: liftedFn, env: { captured vars } } → (ms_closure){ .fn = ..., .env = ... }
// 2. General struct: { x: 1, y: 2 } → (StructType){ .x = 1, .y = 2 }

function genObjectLiteral(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ObjectLiteralData;

	// Detect closure pair: keys are ["fn", "env"] with exactly 2 entries
	if (d.keys.length === 2 && d.keys[0] === "fn" && d.keys[1] === "env") {
		// Closure literal: (ms_closure){ .fn = ..., .env = ... }
		const fnExpr = genExpr(g, p, d.properties[0]);
		const envExpr = genExpr(g, p, d.properties[1]);
		return "(ms_closure){ .fn = (void*)" + fnExpr + ", .env = (void*)&" + envExpr + " }";
	}

	// General struct literal: { .field1 = val1, .field2 = val2 }
	let result = "{ ";
	let i = 0;
	while (i < d.keys.length) {
		if (i > 0) result = result + ", ";
		result = result + "." + mangleFieldName(d.keys[i]) + " = " + genExpr(g, p, d.properties[i]);
		i += 1;
	}
	result = result + " }";
	return result;
}

// ===== Array Literal =====

function genArrayLiteral(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ArrayLiteralData;
	if (d.elements.length === 0) return "{ 0 }";
	let result = "{ ";
	let i = 0;
	while (i < d.elements.length) {
		if (i > 0) result = result + ", ";
		result = result + genExpr(g, p, d.elements[i]);
		i += 1;
	}
	result = result + " }";
	return result;
}

// ===== Arrow Function (non-capturing) =====
// Non-capturing arrows that survive lambda lifting are emitted as function pointers.
// Capturing arrows are already transformed into closure pairs (ObjectLiteral).

function genArrowFunction(g: CGen, p: CProc, node: Node): string {
	// Lambda lifting (Phase 3) lifts all ArrowFunctions — this path is dead.
	return "0 /* unlowered ArrowFunction */";
}

// ===== Update Expression (i++, ++i, i--, --i) =====
// Phase 3 lowers statement-position updates to assignment.
// Expression-position updates survive — emit directly (C supports natively).

function genUpdateExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as UpdateExprData;
	const operand = genExpr(g, p, d.updateArg);
	if (d.isPrefix) return "(" + d.updateOp + operand + ")";
	return "(" + operand + d.updateOp + ")";
}

// ===== New Expression =====
// `new Foo(args)` → `ClassName_new(args)` (constructor call).
// Classes emit ClassName_new() in declarations.ms.

function genNewExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as NewExprData;
	const callee = genExpr(g, p, d.newCallee);
	let args = "";
	let i = 0;
	while (i < d.newArguments.length) {
		if (i > 0) args = args + ", ";
		args = args + genExpr(g, p, d.newArguments[i]);
		i += 1;
	}
	return callee + "_new(" + args + ")";
}

// ===== Move Expression =====
// `move x` → emit inner expression. DRC (Phase 4) already injected
// ms_was_moved(&x) after the move site. Codegen just passes through.

function genMoveExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as MoveExprData;
	return genExpr(g, p, d.moveArg);
}

// ===== Spread Expression =====
// Phase 3 inlines literal spreads: `f(...[a, b])` → `f(a, b)`.
// Dynamic spreads (`f(...arr)`) survive — no C equivalent.
// Emit the inner expression with a warning comment.

function genSpreadExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as SpreadExprData;
	return "/* spread */ " + genExpr(g, p, d.spreadArg);
}

// ===== Function Expression =====
// Non-capturing function expressions are lifted to module-level functions.
// Capturing ones are already transformed to closure pairs by lambda lifting.
// Same pattern as ArrowFunction.

function genFunctionExpr(g: CGen, p: CProc, node: Node): string {
	// Lambda lifting (Phase 3) lifts all FunctionExpr — this path is dead.
	return "0 /* unlowered FunctionExpr */";
}

// ===== Tests =====

import { createCGen, createProc, extract, sec, CSection } from "./context";
import { CheckerContext } from "../../checker/context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { ProgramData, ExprStmtData } from "../../ast/node";

function exprSnippet(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR";
	const prog = pr.value;
	const pd = prog.data as ProgramData;
	if (pd.programStmts.length === 0) return "NO_STMTS";
	const stmt = pd.programStmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return "NOT_EXPR_STMT";
	const es = stmt.data as ExprStmtData;
	const g = createCGen(null as unknown as CheckerContext);
	const p = createProc("test", null as unknown as Type);
	return genExpr(g, p, es.expr);
}

testGroup("C Expr Number", () => {
	test("integer", () => {
		check(exprSnippet("42;") === "42");
	});
	test("float", () => {
		check(exprSnippet("3.14;") === "3.14");
	});
	test("zero", () => {
		check(exprSnippet("0;") === "0");
	});
});

testGroup("C Expr String", () => {
	test("simple string", () => {
		check(exprSnippet("\"hello\";") === "\"hello\"");
	});
});

testGroup("C Expr Bool", () => {
	test("true", () => {
		check(exprSnippet("true;") === "NIM_TRUE");
	});
	test("false", () => {
		check(exprSnippet("false;") === "NIM_FALSE");
	});
});

testGroup("C Expr Null", () => {
	test("null literal", () => {
		check(exprSnippet("null;") === "NIM_NIL");
	});
});

testGroup("C Expr Identifier", () => {
	test("simple name", () => {
		check(exprSnippet("foo;") === "foo");
	});
});

testGroup("C Expr Binary", () => {
	test("addition", () => {
		check(exprSnippet("a + b;") === "(a + b)");
	});
	test("equality", () => {
		check(exprSnippet("x === y;") === "(x == y)");
	});
	test("not equal", () => {
		check(exprSnippet("x !== y;") === "(x != y)");
	});
	test("nested", () => {
		check(exprSnippet("a + b * c;") === "(a + (b * c))");
	});
});

testGroup("C Expr Unary", () => {
	test("negation", () => {
		check(exprSnippet("-x;") === "(-x)");
	});
	test("logical not", () => {
		check(exprSnippet("!flag;") === "(!flag)");
	});
});

testGroup("C Expr Call", () => {
	test("no args", () => {
		check(exprSnippet("foo();") === "foo()");
	});
	test("with args", () => {
		check(exprSnippet("foo(a, b);") === "foo(a, b)");
	});
	test("nested call", () => {
		check(exprSnippet("foo(bar(x));") === "foo(bar(x))");
	});
});

testGroup("C Expr Member", () => {
	test("dot access", () => {
		check(exprSnippet("obj.x;") === "obj.x");
	});
});

testGroup("C Expr Array Access", () => {
	test("bracket access", () => {
		check(exprSnippet("arr[0];") === "arr[0]");
	});
	test("expression index", () => {
		check(exprSnippet("arr[i + 1];") === "arr[(i + 1)]");
	});
});

testGroup("C Expr Ternary", () => {
	test("conditional", () => {
		check(exprSnippet("a ? b : c;") === "(a ? b : c)");
	});
});


testGroup("C Expr Array", () => {
	test("empty array", () => {
		check(exprSnippet("[];") === "{ 0 }");
	});
	test("array with elements", () => {
		check(exprSnippet("[1, 2, 3];") === "{ 1, 2, 3 }");
	});
});

testGroup("C Expr Update", () => {
	test("postfix increment", () => {
		check(exprSnippet("x++;") === "(x++)");
	});
	test("prefix increment", () => {
		check(exprSnippet("++x;") === "(++x)");
	});
	test("postfix decrement", () => {
		check(exprSnippet("x--;") === "(x--)");
	});
	test("prefix decrement", () => {
		check(exprSnippet("--x;") === "(--x)");
	});
});

testGroup("C Expr New", () => {
	test("simple new", () => {
		check(exprSnippet("new Foo();") === "Foo_new()");
	});
	test("new with args", () => {
		check(exprSnippet("new Bar(1, 2);") === "Bar_new(1, 2)");
	});
});

testGroup("C Expr Move", () => {
	test("move identifier", () => {
		check(exprSnippet("move x;") === "x");
	});
	test("move call", () => {
		check(exprSnippet("move f();") === "f()");
	});
});
