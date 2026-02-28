// Raiser codegen — Top-level generator + tests
// AST Program → RaiserModule bytecode.

import { test, check, testGroup } from "std/testing";
import {
	Node, NodeKind, ProgramData, FunctionDeclData,
	ExportDeclData, DecoratedDeclData
} from "../../ast/node";
import { parseSource } from "../../parser/index";
import { RaiserOpcode } from "../../raiser/bytecode";
import { RaiserValue, raiserNil } from "../../raiser/value";
import {
	RaiserModule, RaiserFunction,
	createRaiserFunction, createRaiserModule
} from "../../raiser/module";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";
import {
	RaiserCompState, RaiserFuncMap, RaiserFuncEntry,
	createCompState, emitLoadConst, emitHalt, emitRet, allocReg,
	declareLocal, registerFunc, declareEnum
} from "./context";
import { compileStmt } from "./statements";

// --- Unwrap ExportDecl / DecoratedDecl to find inner FunctionDecl ---

function unwrapToFuncDecl(node: Node): Node {
	if (node.kind === NodeKind.FunctionDecl) return node;
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return unwrapToFuncDecl(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return unwrapToFuncDecl(d.decoratedNode);
	}
	return null as unknown as Node;
}

function unwrapToEnumDecl(node: Node): Node {
	if (node.kind === NodeKind.EnumDecl) return node;
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return unwrapToEnumDecl(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return unwrapToEnumDecl(d.decoratedNode);
	}
	return null as unknown as Node;
}

// --- Top-level: AST → RaiserModule ---
// Two-phase compilation:
//   Phase 1: Collect FunctionDecl names → assign module indices
//   Phase 2: Compile each function body + top-level code

export function generateRaiser(program: Node): RaiserModule {
	const pd = program.data as ProgramData;
	const functions: RaiserFunction[] = [];

	// Phase 1: Collect function and enum declarations (unwrap export/decorated)
	const funcMapItems: RaiserFuncEntry[] = [];
	const funcMap: RaiserFuncMap = { items: funcMapItems };
	const enumMapItems: RaiserFuncEntry[] = [];
	const enumMap: RaiserFuncMap = { items: enumMapItems };
	let funcIdx = 0;
	let i = 0;
	while (i < pd.programStmts.length) {
		const fnNode = unwrapToFuncDecl(pd.programStmts[i]);
		if (fnNode !== null) {
			const fd = fnNode.data as FunctionDeclData;
			const entry: RaiserFuncEntry = { name: fd.fnName, index: funcIdx };
			funcMap.items.push(entry);
			funcIdx = funcIdx + 1;
		}
		const enumNode = unwrapToEnumDecl(pd.programStmts[i]);
		if (enumNode !== null) {
			// EnumDeclData = { enumName: string, enumMembers: string[] }
			// Reuse FunctionDeclData overlay: fnName ≡ enumName, params ≡ enumMembers
			const ed = enumNode.data as FunctionDeclData;
			let ei = 0;
			while (ei < ed.params.length) {
				const key = ed.fnName + "." + ed.params[ei];
				const me: RaiserFuncEntry = { name: key, index: ei };
				enumMap.items.push(me);
				ei = ei + 1;
			}
		}
		i = i + 1;
	}

	// Phase 2a: Compile each function body
	i = 0;
	while (i < pd.programStmts.length) {
		const fnNode = unwrapToFuncDecl(pd.programStmts[i]);
		if (fnNode !== null) {
			const fd = fnNode.data as FunctionDeclData;
			const func = compileFuncBody(funcMap, enumMap, fd.fnName, fd.params, fd.fnBody, fd.params.length);
			functions.push(func);
		}
		i = i + 1;
	}

	// Phase 2b: Compile top-level code as entry function
	const entryIdx = functions.length;
	const s = createCompState();
	s.funcMap = funcMap;
	s.enumMap = enumMap;
	i = 0;
	while (i < pd.programStmts.length) {
		compileStmt(s, pd.programStmts[i]);
		i = i + 1;
	}

	// Ensure entry terminates
	if (s.code.length === 0) {
		emitLoadConst(s, 0, raiserNil());
		emitHalt(s);
	} else {
		const lastInst = s.code[s.code.length - 1];
		if (lastInst.op !== RaiserOpcode.Ret && lastInst.op !== RaiserOpcode.Halt) {
			emitHalt(s);
		}
	}

	const entryFunc = createRaiserFunction("main", s.code, s.constants, 0, 0, s.nextReg);
	functions.push(entryFunc);

	return createRaiserModule("main", functions, entryIdx);
}

// --- Compile a function body ---

function compileFuncBody(funcMap: RaiserFuncMap, enumMap: RaiserFuncMap, fnName: string, params: string[], body: Node, arity: number): RaiserFunction {
	const s = createCompState();
	s.funcMap = funcMap;
	s.enumMap = enumMap;

	// Declare params as locals R[0..arity-1]
	let i = 0;
	while (i < arity) {
		const paramName = params[i];
		const reg = allocReg(s);
		declareLocal(s, paramName, reg);
		i = i + 1;
	}

	// Compile body
	compileStmt(s, body);

	// Ensure function terminates with Ret
	if (s.code.length === 0) {
		const nilReg = allocReg(s);
		emitLoadConst(s, nilReg, raiserNil());
		emitRet(s, nilReg);
	} else {
		const lastInst = s.code[s.code.length - 1];
		if (lastInst.op !== RaiserOpcode.Ret) {
			const nilReg = allocReg(s);
			emitLoadConst(s, nilReg, raiserNil());
			emitRet(s, nilReg);
		}
	}

	return createRaiserFunction(fnName, s.code, s.constants, arity, 0, s.nextReg);
}

// --- Test helper ---

function evalRaiser(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		check(false);
		// Return a dummy context to prevent crash
		const dummyMod = generateRaiser(parseSource("return 0;").value);
		const ctx = createContext();
		load(ctx, dummyMod);
		execute(ctx);
		return ctx;
	}
	const mod = generateRaiser(parseResult.value);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

// --- Tests ---

testGroup("Raiser codegen", () => {
	test("return number", () => {
		const ctx = evalRaiser("return 42;");
		check(ctx.lastResult.intVal === 42);
	});

	test("return addition", () => {
		const ctx = evalRaiser("return 2 + 3;");
		check(ctx.lastResult.intVal === 5);
	});

	test("return complex: 10 - 3 * 2 + 1", () => {
		const ctx = evalRaiser("return 10 - 3 * 2 + 1;");
		check(ctx.lastResult.intVal === 5);
	});

	test("return negation", () => {
		const ctx = evalRaiser("return -7;");
		check(ctx.lastResult.intVal === -7);
	});

	test("console.log captures output", () => {
		const ctx = evalRaiser("console.log(42);");
		check(ctx.lastOutput === "42\n");
	});

	test("console.log expression", () => {
		const ctx = evalRaiser("console.log(2 + 3);");
		check(ctx.lastOutput === "5\n");
	});

	test("(2 + 3) * 4 = 20", () => {
		const ctx = evalRaiser("return (2 + 3) * 4;");
		check(ctx.lastResult.intVal === 20);
	});

	test("84 / 2 = 42", () => {
		const ctx = evalRaiser("return 84 / 2;");
		check(ctx.lastResult.intVal === 42);
	});

	test("17 % 5 = 2", () => {
		const ctx = evalRaiser("return 17 % 5;");
		check(ctx.lastResult.intVal === 2);
	});
});

testGroup("Raiser variables", () => {
	test("const declaration and reference", () => {
		const ctx = evalRaiser("const x = 42; return x;");
		check(ctx.lastResult.intVal === 42);
	});

	test("variable arithmetic", () => {
		const ctx = evalRaiser("const a = 10; const b = 20; return a + b;");
		check(ctx.lastResult.intVal === 30);
	});

	test("let assignment", () => {
		const ctx = evalRaiser("let x = 1; x = 42; return x;");
		check(ctx.lastResult.intVal === 42);
	});

	test("chained variable ops", () => {
		const ctx = evalRaiser("const a = 5; const b = a * 2; const c = b + a; return c;");
		check(ctx.lastResult.intVal === 15);
	});
});

testGroup("Raiser comparisons", () => {
	test("greater than true", () => {
		const ctx = evalRaiser("return 5 > 3;");
		check(ctx.lastResult.intVal === 1);
	});

	test("greater than false", () => {
		const ctx = evalRaiser("return 3 > 5;");
		check(ctx.lastResult.intVal === 0);
	});

	test("equal true", () => {
		const ctx = evalRaiser("return 7 == 7;");
		check(ctx.lastResult.intVal === 1);
	});

	test("not equal", () => {
		const ctx = evalRaiser("return 5 != 3;");
		check(ctx.lastResult.intVal === 1);
	});

	test("less than or equal", () => {
		const ctx = evalRaiser("return 3 <= 3;");
		check(ctx.lastResult.intVal === 1);
	});
});

testGroup("Raiser if-else", () => {
	test("if true branch", () => {
		const ctx = evalRaiser("if (5 > 3) { return 1; } else { return 0; }");
		check(ctx.lastResult.intVal === 1);
	});

	test("if false branch", () => {
		const ctx = evalRaiser("if (3 > 5) { return 1; } else { return 0; }");
		check(ctx.lastResult.intVal === 0);
	});

	test("if without else", () => {
		const ctx = evalRaiser("const x = 5; if (x > 10) { return 0; } return x;");
		check(ctx.lastResult.intVal === 5);
	});

	test("if with variable", () => {
		const ctx = evalRaiser("let r = 0; if (1 > 0) { r = 42; } return r;");
		check(ctx.lastResult.intVal === 42);
	});
});

testGroup("Raiser while", () => {
	test("sum 1..5 = 15", () => {
		const ctx = evalRaiser("let sum = 0; let i = 1; while (i <= 5) { sum = sum + i; i = i + 1; } return sum;");
		check(ctx.lastResult.intVal === 15);
	});

	test("countdown", () => {
		const ctx = evalRaiser("let n = 10; while (n > 0) { n = n - 1; } return n;");
		check(ctx.lastResult.intVal === 0);
	});

	test("break exits loop", () => {
		const ctx = evalRaiser("let i = 0; while (i < 100) { if (i == 5) { break; } i = i + 1; } return i;");
		check(ctx.lastResult.intVal === 5);
	});

	test("continue skips iteration", () => {
		const ctx = evalRaiser("let sum = 0; let i = 0; while (i < 5) { i = i + 1; if (i == 3) { continue; } sum = sum + i; } return sum;");
		check(ctx.lastResult.intVal === 12);
	});
});

testGroup("Raiser functions", () => {
	test("simple function call", () => {
		const ctx = evalRaiser("function add(a, b) { return a + b; } return add(3, 4);");
		check(ctx.lastResult.intVal === 7);
	});

	test("function no args", () => {
		const ctx = evalRaiser("function five() { return 5; } return five();");
		check(ctx.lastResult.intVal === 5);
	});

	test("nested calls: f(g(2))", () => {
		const ctx = evalRaiser("function triple(x) { return x * 3; } function inc(x) { return x + 1; } return inc(triple(2));");
		check(ctx.lastResult.intVal === 7);
	});

	test("function with local variable", () => {
		const ctx = evalRaiser("function square(n) { const r = n * n; return r; } return square(6);");
		check(ctx.lastResult.intVal === 36);
	});

	test("recursive factorial", () => {
		const ctx = evalRaiser("function fact(n) { if (n <= 1) { return 1; } return n * fact(n - 1); } return fact(5);");
		check(ctx.lastResult.intVal === 120);
	});

	test("multiple function calls", () => {
		const ctx = evalRaiser("function add(a, b) { return a + b; } const x = add(10, 20); const y = add(x, 5); return y;");
		check(ctx.lastResult.intVal === 35);
	});
});

testGroup("Raiser strings", () => {
	test("string literal return", () => {
		const ctx = evalRaiser("return \"hello\";");
		check(ctx.lastResult.strVal === "hello");
	});

	test("console.log string", () => {
		const ctx = evalRaiser("console.log(\"world\");");
		check(ctx.lastOutput === "world\n");
	});
});

testGroup("Raiser logical", () => {
	test("true && value", () => {
		const ctx = evalRaiser("return 1 && 42;");
		check(ctx.lastResult.intVal === 42);
	});

	test("false && value", () => {
		const ctx = evalRaiser("return 0 && 42;");
		check(ctx.lastResult.intVal === 0);
	});

	test("false || value", () => {
		const ctx = evalRaiser("return 0 || 7;");
		check(ctx.lastResult.intVal === 7);
	});

	test("true || value", () => {
		const ctx = evalRaiser("return 1 || 99;");
		check(ctx.lastResult.intVal === 1);
	});

	test("logical in if condition", () => {
		const ctx = evalRaiser("const a = 1; const b = 2; if (a > 0 && b > 0) { return 1; } return 0;");
		check(ctx.lastResult.intVal === 1);
	});
});

testGroup("Raiser complex programs", () => {
	test("recursive fibonacci", () => {
		const ctx = evalRaiser("function fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } return fib(10);");
		check(ctx.lastResult.intVal === 55);
	});

	test("iterative fibonacci", () => {
		const ctx = evalRaiser("let a = 0; let b = 1; let i = 0; while (i < 10) { let tmp = a + b; a = b; b = tmp; i = i + 1; } return a;");
		check(ctx.lastResult.intVal === 55);
	});

	test("mutual recursion: isEven/isOdd", () => {
		const ctx = evalRaiser("function isEven(n) { if (n == 0) { return 1; } return isOdd(n - 1); } function isOdd(n) { if (n == 0) { return 0; } return isEven(n - 1); } return isEven(10);");
		check(ctx.lastResult.intVal === 1);
	});

	test("GCD", () => {
		const ctx = evalRaiser("function gcd(a, b) { if (b == 0) { return a; } return gcd(b, a % b); } return gcd(48, 18);");
		check(ctx.lastResult.intVal === 6);
	});

	test("nested loops: multiplication table sum", () => {
		const ctx = evalRaiser("let sum = 0; let i = 1; while (i <= 5) { let j = 1; while (j <= 5) { sum = sum + i * j; j = j + 1; } i = i + 1; } return sum;");
		check(ctx.lastResult.intVal === 225);
	});

	test("fibonacci with console.log", () => {
		const ctx = evalRaiser("function fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } let i = 0; while (i <= 6) { console.log(fib(i)); i = i + 1; }");
		check(ctx.lastOutput === "0\n1\n1\n2\n3\n5\n8\n");
	});
});

testGroup("Raiser ternary", () => {
	test("true branch", () => {
		const ctx = evalRaiser("return 1 > 0 ? 42 : 99;");
		check(ctx.lastResult.intVal === 42);
	});

	test("false branch", () => {
		const ctx = evalRaiser("return 0 > 1 ? 42 : 99;");
		check(ctx.lastResult.intVal === 99);
	});

	test("nested ternary", () => {
		const ctx = evalRaiser("const x = 5; return x > 10 ? 1 : x > 3 ? 2 : 3;");
		check(ctx.lastResult.intVal === 2);
	});

	test("ternary in expression", () => {
		const ctx = evalRaiser("const a = 10; const b = 20; return (a > b ? a : b) + 1;");
		check(ctx.lastResult.intVal === 21);
	});
});

testGroup("Raiser update expr", () => {
	test("postfix increment", () => {
		const ctx = evalRaiser("let x = 5; x++; return x;");
		check(ctx.lastResult.intVal === 6);
	});

	test("prefix increment", () => {
		const ctx = evalRaiser("let x = 5; ++x; return x;");
		check(ctx.lastResult.intVal === 6);
	});

	test("postfix returns old value", () => {
		const ctx = evalRaiser("let x = 5; let y = x++; return y;");
		check(ctx.lastResult.intVal === 5);
	});

	test("prefix returns new value", () => {
		const ctx = evalRaiser("let x = 5; let y = ++x; return y;");
		check(ctx.lastResult.intVal === 6);
	});

	test("decrement", () => {
		const ctx = evalRaiser("let x = 10; x--; x--; return x;");
		check(ctx.lastResult.intVal === 8);
	});

	test("increment in loop", () => {
		const ctx = evalRaiser("let sum = 0; let i = 0; while (i < 5) { sum = sum + i; i++; } return sum;");
		check(ctx.lastResult.intVal === 10);
	});
});

testGroup("Raiser do-while", () => {
	test("executes at least once", () => {
		const ctx = evalRaiser("let x = 0; do { x = 42; } while (0 > 1); return x;");
		check(ctx.lastResult.intVal === 42);
	});

	test("loops until false", () => {
		const ctx = evalRaiser("let i = 0; do { i = i + 1; } while (i < 5); return i;");
		check(ctx.lastResult.intVal === 5);
	});

	test("break in do-while", () => {
		const ctx = evalRaiser("let i = 0; do { if (i == 3) { break; } i = i + 1; } while (i < 100); return i;");
		check(ctx.lastResult.intVal === 3);
	});
});

testGroup("Raiser export unwrap", () => {
	test("export function with return", () => {
		const ctx = evalRaiser("export function triple(n) { return n * 3; } return triple(5);");
		check(ctx.lastResult.intVal === 15);
	});

	test("export function in expression", () => {
		const ctx = evalRaiser("export function add(a, b) { return a + b; } return add(10, add(3, 4));");
		check(ctx.lastResult.intVal === 17);
	});
});

testGroup("Raiser arrays", () => {
	test("array literal and index access", () => {
		const ctx = evalRaiser("const arr = [10, 20, 30]; return arr[1];");
		check(ctx.lastResult.intVal === 20);
	});

	test("array length", () => {
		const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; return arr.length;");
		check(ctx.lastResult.intVal === 5);
	});

	test("array push and length", () => {
		const ctx = evalRaiser("const arr = [1, 2]; arr.push(3); return arr.length;");
		check(ctx.lastResult.intVal === 3);
	});

	test("array push and access", () => {
		const ctx = evalRaiser("const arr = []; arr.push(42); return arr[0];");
		check(ctx.lastResult.intVal === 42);
	});

	test("array index assignment", () => {
		const ctx = evalRaiser("const arr = [0, 0, 0]; arr[1] = 99; return arr[1];");
		check(ctx.lastResult.intVal === 99);
	});

	test("array iteration with while loop", () => {
		const ctx = evalRaiser("const arr = [10, 20, 30]; let sum = 0; let i = 0; while (i < arr.length) { sum = sum + arr[i]; i = i + 1; } return sum;");
		check(ctx.lastResult.intVal === 60);
	});

	test("array as function argument", () => {
		const ctx = evalRaiser("function sum(arr) { let s = 0; let i = 0; while (i < arr.length) { s = s + arr[i]; i = i + 1; } return s; } return sum([1, 2, 3, 4]);");
		check(ctx.lastResult.intVal === 10);
	});

	test("build array with push in loop", () => {
		const ctx = evalRaiser("const arr = []; let i = 0; while (i < 5) { arr.push(i * i); i = i + 1; } return arr[3];");
		check(ctx.lastResult.intVal === 9);
	});

	test("nested array access in expression", () => {
		const ctx = evalRaiser("const arr = [2, 3, 5]; return arr[0] * arr[1] + arr[2];");
		check(ctx.lastResult.intVal === 11);
	});
});

testGroup("Raiser objects", () => {
	test("object literal and field access", () => {
		const ctx = evalRaiser("const obj = { x: 10, y: 20 }; return obj.x;");
		check(ctx.lastResult.intVal === 10);
	});

	test("object field access second field", () => {
		const ctx = evalRaiser("const obj = { x: 10, y: 20 }; return obj.y;");
		check(ctx.lastResult.intVal === 20);
	});

	test("object field mutation", () => {
		const ctx = evalRaiser("const obj = { x: 1 }; obj.x = 99; return obj.x;");
		check(ctx.lastResult.intVal === 99);
	});

	test("object as function argument", () => {
		const ctx = evalRaiser("function sum(o) { return o.a + o.b; } return sum({ a: 3, b: 7 });");
		check(ctx.lastResult.intVal === 10);
	});

	test("object with computed values", () => {
		const ctx = evalRaiser("const a = 5; const b = 10; const obj = { sum: a + b }; return obj.sum;");
		check(ctx.lastResult.intVal === 15);
	});

	test("object in array", () => {
		const ctx = evalRaiser("const arr = [{ val: 1 }, { val: 2 }]; const item = arr[1]; return item.val;");
		check(ctx.lastResult.intVal === 2);
	});

	test("array in object", () => {
		const ctx = evalRaiser("const obj = { items: [1, 2, 3] }; return obj.items.length;");
		check(ctx.lastResult.intVal === 3);
	});
});

testGroup("Raiser string ops", () => {
	test("string concat", () => {
		const ctx = evalRaiser("return \"hello\" + \" world\";");
		check(ctx.lastResult.strVal === "hello world");
	});

	test("string concat with variable", () => {
		const ctx = evalRaiser("const s = \"hi\"; return s + \"!\";");
		check(ctx.lastResult.strVal === "hi!");
	});

	test("string equality true", () => {
		const ctx = evalRaiser("return \"abc\" == \"abc\";");
		check(ctx.lastResult.intVal === 1);
	});

	test("string equality false", () => {
		const ctx = evalRaiser("return \"abc\" == \"def\";");
		check(ctx.lastResult.intVal === 0);
	});

	test("string inequality", () => {
		const ctx = evalRaiser("return \"abc\" != \"def\";");
		check(ctx.lastResult.intVal === 1);
	});

	test("string + number coercion", () => {
		const ctx = evalRaiser("return \"value: \" + 42;");
		check(ctx.lastResult.strVal === "value: 42");
	});

	test("function returning string", () => {
		const ctx = evalRaiser("function greet(name) { return \"Hello, \" + name; } return greet(\"world\");");
		check(ctx.lastResult.strVal === "Hello, world");
	});

	test("multi-concat chain", () => {
		const ctx = evalRaiser("return \"a\" + \"b\" + \"c\";");
		check(ctx.lastResult.strVal === "abc");
	});

	test("console.log string concat", () => {
		const ctx = evalRaiser("console.log(\"sum: \" + (2 + 3));");
		check(ctx.lastOutput === "sum: 5\n");
	});
});

testGroup("Raiser for-loops", () => {
	test("C-style for: sum 0..4", () => {
		const ctx = evalRaiser("let sum = 0; for (let i = 0; i < 5; i++) { sum = sum + i; } return sum;");
		check(ctx.lastResult.intVal === 10);
	});

	test("C-style for: factorial", () => {
		const ctx = evalRaiser("let result = 1; for (let i = 1; i <= 5; i++) { result = result * i; } return result;");
		check(ctx.lastResult.intVal === 120);
	});

	test("C-style for: break", () => {
		const ctx = evalRaiser("let i = 0; for (i = 0; i < 100; i++) { if (i == 7) { break; } } return i;");
		check(ctx.lastResult.intVal === 7);
	});

	test("for-of: sum array elements", () => {
		const ctx = evalRaiser("const arr = [10, 20, 30]; let sum = 0; for (const x of arr) { sum = sum + x; } return sum;");
		check(ctx.lastResult.intVal === 60);
	});

	test("for-of: count elements", () => {
		const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; let count = 0; for (const x of arr) { count = count + 1; } return count;");
		check(ctx.lastResult.intVal === 5);
	});

	test("for-of: break early", () => {
		const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; let sum = 0; for (const x of arr) { if (x > 3) { break; } sum = sum + x; } return sum;");
		check(ctx.lastResult.intVal === 6);
	});
});

testGroup("Raiser compound assign", () => {
	test("+=", () => {
		const ctx = evalRaiser("let x = 10; x += 5; return x;");
		check(ctx.lastResult.intVal === 15);
	});

	test("-=", () => {
		const ctx = evalRaiser("let x = 10; x -= 3; return x;");
		check(ctx.lastResult.intVal === 7);
	});

	test("*=", () => {
		const ctx = evalRaiser("let x = 4; x *= 3; return x;");
		check(ctx.lastResult.intVal === 12);
	});

	test("/=", () => {
		const ctx = evalRaiser("let x = 20; x /= 4; return x;");
		check(ctx.lastResult.intVal === 5);
	});

	test("%=", () => {
		const ctx = evalRaiser("let x = 17; x %= 5; return x;");
		check(ctx.lastResult.intVal === 2);
	});

	test("+= in loop", () => {
		const ctx = evalRaiser("let sum = 0; for (let i = 1; i <= 5; i++) { sum += i; } return sum;");
		check(ctx.lastResult.intVal === 15);
	});

	test("+= string concat", () => {
		const ctx = evalRaiser("let s = \"hello\"; s += \" world\"; return s;");
		check(ctx.lastResult.strVal === "hello world");
	});
});

testGroup("Raiser enums", () => {
	test("enum member access", () => {
		const ctx = evalRaiser("enum Color { Red, Green, Blue } return Color.Green;");
		check(ctx.lastResult.intVal === 1);
	});

	test("enum first member is 0", () => {
		const ctx = evalRaiser("enum Dir { Up, Down, Left, Right } return Dir.Up;");
		check(ctx.lastResult.intVal === 0);
	});

	test("enum last member", () => {
		const ctx = evalRaiser("enum Dir { Up, Down, Left, Right } return Dir.Right;");
		check(ctx.lastResult.intVal === 3);
	});

	test("enum in comparison", () => {
		const ctx = evalRaiser("enum Color { Red, Green, Blue } const c = Color.Blue; return c == 2;");
		check(ctx.lastResult.intVal === 1);
	});

	test("enum in if condition", () => {
		const ctx = evalRaiser("enum State { Off, On } const s = State.On; if (s == State.On) { return 42; } return 0;");
		check(ctx.lastResult.intVal === 42);
	});

	test("enum in function", () => {
		const ctx = evalRaiser("enum Color { Red, Green, Blue } function isBlue(c) { if (c == Color.Blue) { return 1; } return 0; } return isBlue(Color.Blue);");
		check(ctx.lastResult.intVal === 1);
	});

	test("enum arithmetic", () => {
		const ctx = evalRaiser("enum Op { Add, Sub, Mul } return Op.Mul * 10;");
		check(ctx.lastResult.intVal === 20);
	});
});

testGroup("Raiser string methods", () => {
	test("string .length literal", () => {
		const ctx = evalRaiser("return \"hello\".length;");
		check(ctx.lastResult.intVal === 5);
	});

	test("string .length variable", () => {
		const ctx = evalRaiser("const s = \"abc\"; return s.length;");
		check(ctx.lastResult.intVal === 3);
	});

	test("empty string .length", () => {
		const ctx = evalRaiser("return \"\".length;");
		check(ctx.lastResult.intVal === 0);
	});

	test("charAt", () => {
		const ctx = evalRaiser("return \"hello\".charAt(1);");
		check(ctx.lastResult.strVal === "e");
	});

	test("charAt variable", () => {
		const ctx = evalRaiser("const s = \"world\"; return s.charAt(0);");
		check(ctx.lastResult.strVal === "w");
	});

	test("slice", () => {
		const ctx = evalRaiser("return \"hello world\".slice(0, 5);");
		check(ctx.lastResult.strVal === "hello");
	});

	test("slice variable", () => {
		const ctx = evalRaiser("const s = \"abcdef\"; return s.slice(2, 4);");
		check(ctx.lastResult.strVal === "cd");
	});

	test("string length in condition", () => {
		const ctx = evalRaiser("const s = \"abc\"; if (s.length > 2) { return 1; } return 0;");
		check(ctx.lastResult.intVal === 1);
	});
});

testGroup("Raiser closures", () => {
	test("non-capturing closure", () => {
		const ctx = evalRaiser("function lifted(_e) { return 42; } const f = { fn: lifted, env: {} }; return f();");
		check(ctx.lastResult.intVal === 42);
	});

	test("closure with capture", () => {
		const ctx = evalRaiser("function lifted(_e, y) { return _e.x + y; } const e = { x: 5 }; const f = { fn: lifted, env: e }; return f(3);");
		check(ctx.lastResult.intVal === 8);
	});

	test("higher-order: makeAdder", () => {
		const ctx = evalRaiser("function liftedAdd(_e, x) { return _e.n + x; } function makeAdder(n) { return { fn: liftedAdd, env: { n: n } }; } const add5 = makeAdder(5); return add5(3);");
		check(ctx.lastResult.intVal === 8);
	});

	test("multiple captures", () => {
		const ctx = evalRaiser("function lifted(_e) { return _e.a + _e.b; } const f = { fn: lifted, env: { a: 3, b: 7 } }; return f();");
		check(ctx.lastResult.intVal === 10);
	});

	test("chained call: makeAdder(5)(3)", () => {
		const ctx = evalRaiser("function liftedAdd(_e, x) { return _e.n + x; } function makeAdder(n) { return { fn: liftedAdd, env: { n: n } }; } return makeAdder(5)(3);");
		check(ctx.lastResult.intVal === 8);
	});

	test("closure in loop", () => {
		const ctx = evalRaiser("function lifted(_e) { return _e.i; } let sum = 0; let i = 0; while (i < 5) { const f = { fn: lifted, env: { i: i } }; sum = sum + f(); i = i + 1; } return sum;");
		check(ctx.lastResult.intVal === 10);
	});

	test("closure returning closure", () => {
		const ctx = evalRaiser("function inner(_e2) { return _e2.x + _e2.y; } function outer(_e1) { return { fn: inner, env: { x: _e1.a, y: _e1.b } }; } const f = { fn: outer, env: { a: 3, b: 7 } }; const g = f(); return g();");
		check(ctx.lastResult.intVal === 10);
	});
});
