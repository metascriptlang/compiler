// Raiser codegen — Top-level generator + tests
// AST Program → RaiserModule bytecode.


import {
	Node, NodeKind, ProgramData, FunctionDeclData,
	ExportDeclData, DecoratedDeclData, EnumDeclData,
	ClassDeclData, MethodDeclData, ConstructorDeclData, PropertyDeclData
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { RaiserOpcode, RaiserInstruction, raiserABC } from "../../raiser/bytecode";
import {
	RaiserValue, RaiserValueKind, raiserNil, raiserString,
	heapObjectGetField, heapObjectGetString, heapObjectGetObjectHandle,
	heapArrayGet, heapArrayLen
} from "../../raiser/value";
import {
	RaiserModule, RaiserFunction,
	createRaiserFunction, createRaiserModule
} from "../../raiser/module";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";
import {
	RaiserFuncMap, RaiserFuncEntry, RaiserBuiltinMap, RaiserBuiltinEntry,
	createCompState, emitInst, emitLoadConst, emitRet, allocReg,
	addConst, declareLocal, resetTemps, resolveFunc, emitClosurePair,
} from "./context";
import { compileStmt } from "./statements";
import { compileExpr } from "./expressions";
import { registerCoreParsers } from "../../parser/statements/core";

registerCoreParsers();

// --- Unwrap ExportDecl / DecoratedDecl to find inner declaration of a given kind ---

function unwrapToKind(node: Node, targetKind: NodeKind): Node {
	if (node.kind === targetKind) return node;
	return match (node.kind) {
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			return unwrapToKind(d.exportedDecl, targetKind);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			return unwrapToKind(d.decoratedNode, targetKind);
		},
		_ => null as unknown as Node,
	};
}

export function unwrapToFuncDecl(node: Node): Node {
	return unwrapToKind(node, NodeKind.FunctionDecl);
}

export function unwrapToEnumDecl(node: Node): Node {
	return unwrapToKind(node, NodeKind.EnumDecl);
}

export function unwrapToClassDecl(node: Node): Node {
	return unwrapToKind(node, NodeKind.ClassDecl);
}

// --- Top-level: AST → RaiserModule ---
// Two-phase compilation:
//   Phase 1: Collect FunctionDecl names → assign module indices
//   Phase 2: Compile each function body + top-level code

export function generateRaiser(program: Node): RaiserModule {
	const input: RaiserModuleInput = { modulePath: "main", program: program };
	const modules: RaiserModuleInput[] = [];
	modules.push(input);
	return generateRaiserProject(modules);
}

// --- Expression-body detection ---
// Returns true if the node is an expression (not a statement), used to detect
// arrow function expression bodies like `(x) => x * 2`.

function isExpressionBody(node: Node): boolean {
	const k = node.kind;
	return k !== NodeKind.BlockStmt && k !== NodeKind.ReturnStmt &&
		k !== NodeKind.IfStmt && k !== NodeKind.WhileStmt &&
		k !== NodeKind.ForStmt && k !== NodeKind.ForOfStmt &&
		k !== NodeKind.ExprStmt && k !== NodeKind.VariableDecl &&
		k !== NodeKind.DoWhileStmt;
}

// --- Compile a function body ---

export function compileFuncBody(funcMap: RaiserFuncMap, enumMap: RaiserFuncMap, fnName: string, params: string[], body: Node, arity: number): RaiserFunction {
	const s = createCompState();
	s.funcMap = funcMap;
	s.enumMap = enumMap;

	// Declare params as locals R[0..arity-1]
	for (let i = 0; i < arity; i += 1) {
		const paramName = params[i];
		const reg = allocReg(s);
		declareLocal(s, paramName, reg);
	}

	// Expression-body functions (e.g., arrow `(x) => x * 2` lifted to FunctionDecl):
	// body is a bare expression, not a statement — compile as return <expr>.
	if (isExpressionBody(body)) {
		const exprReg = compileExpr(s, body);
		emitRet(s, exprReg);
	} else {
		compileStmt(s, body);
	}

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

	return createRaiserFunction(fnName, s.code, s.constants, arity, 0, s.maxRegSeen);
}

// --- Class constructor compilation ---
// Creates ClassName_new(params...): allocates object, sets property defaults,
// stores method closures, executes ctor body, returns this.

function compileClassConstructor(
	funcMap: RaiserFuncMap, enumMap: RaiserFuncMap,
	className: string, classBody: Node[],
	ctorParams: string[], ctorBody: Node
): RaiserFunction {
	const s = createCompState();
	s.funcMap = funcMap;
	s.enumMap = enumMap;

	// Declare ctor params
	const arity = ctorParams.length;
	for (let i = 0; i < arity; i += 1) {
		const reg = allocReg(s);
		declareLocal(s, ctorParams[i], reg);
	}

	// Create this object
	const thisReg = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.NewObject, thisReg, 0, 0));
	declareLocal(s, "this", thisReg);

	// Set default properties (nil)
	for (let ci = 0; ci < classBody.length; ci += 1) {
		if (classBody[ci].kind === NodeKind.PropertyDecl) {
			const pd = classBody[ci].data as PropertyDeclData;
			const nilReg = allocReg(s);
			emitLoadConst(s, nilReg, raiserNil());
			const nameIdx = addConst(s, raiserString(pd.propName));
			emitInst(s, raiserABC(RaiserOpcode.StoreField, thisReg, nameIdx, nilReg));
		}
	}

	// Store method closures: { fn: funcIdx, env: this }
	for (let ci = 0; ci < classBody.length; ci += 1) {
		if (classBody[ci].kind === NodeKind.MethodDecl) {
			const md = classBody[ci].data as MethodDeclData;
			const methodKey = `${className}_${md.methodName}`;
			const methodIdx = resolveFunc(s, methodKey);
			if (methodIdx >= 0) {
				const closureReg = emitClosurePair(s, methodIdx, thisReg);
				const methodNameIdx = addConst(s, raiserString(md.methodName));
				emitInst(s, raiserABC(RaiserOpcode.StoreField, thisReg, methodNameIdx, closureReg));
			}
		}
	}

	// Execute constructor body
	if (ctorBody !== null) {
		compileStmt(s, ctorBody);
	}

	// Always return this
	emitRet(s, thisReg);

	return createRaiserFunction(className + "_new", s.code, s.constants, arity, 0, s.maxRegSeen);
}

// --- Incremental append into a shared image (comptime engine) ---
// Compiles a program's FunctionDecls into an existing image + funcMap, assigning
// each an ABSOLUTE index (base + local position) so Call/closure funcIdx resolve
// image-wide with no relocation. Enums fold into the shared enumMap. Returns the
// absolute index assigned to `wantFn` (-1 if not present).
interface RaiserReservedSlot { idx: number; fnName: string; params: string[]; body: Node; arity: number; }

export function appendProgramToImage(image: RaiserModule, funcMap: RaiserFuncMap, enumMap: RaiserFuncMap, program: Node, wantFn: string): number {
	const pd = program.data as ProgramData;
	let wantIdx = -1;

	const reserved: RaiserReservedSlot[] = [];

	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const fnNode = unwrapToFuncDecl(pd.programStmts[i]);
		if (fnNode !== null) {
			const fd = fnNode.data as FunctionDeclData;
			const idx = image.functions.length;
			image.functions.push(raiserPlaceholderFunc());
			const entry: RaiserFuncEntry = { name: fd.fnName, index: idx };
			funcMap.items.push(entry);
			if (fd.fnName === wantFn) wantIdx = idx;
			reserved.push({ idx, fnName: fd.fnName, params: fd.params, body: fd.fnBody, arity: fd.params.length });
		}
		const enumNode = unwrapToEnumDecl(pd.programStmts[i]);
		if (enumNode !== null) {
			const ed = enumNode.data as EnumDeclData;
			for (let ei = 0; ei < ed.enumMembers.length; ei += 1) {
				const val = (ed.enumValues !== null && ei < ed.enumValues.length) ? ed.enumValues[ei] : ei;
				const eEntry: RaiserFuncEntry = { name: `${ed.enumName}.${ed.enumMembers[ei]}`, index: val };
				enumMap.items.push(eEntry);
			}
		}
	}

	for (let i = 0; i < reserved.length; i += 1) {
		const r = reserved[i];
		const func = compileFuncBody(funcMap, enumMap, r.fnName, r.params, r.body, r.arity);
		image.functions[r.idx] = func;
	}
	return wantIdx;
}

function raiserPlaceholderFunc(): RaiserFunction {
	const code: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	return createRaiserFunction("__placeholder", code, [], 0, 0, 1);
}

// --- Project-level compilation ---
// Unity build: flatten all modules' functions into a single RaiserModule.
// VM needs zero changes — Call opcode already indexes by position.

export interface RaiserModuleInput {
	modulePath: string;
	program: Node;
}

export function generateRaiserProject(modules: RaiserModuleInput[]): RaiserModule {
	const functions: RaiserFunction[] = [];

	// --- Pass 1: Global declaration collection ---
	const globalFuncMapItems: RaiserFuncEntry[] = [];
	const globalFuncMap: RaiserFuncMap = { items: globalFuncMapItems };
	const globalEnumMapItems: RaiserFuncEntry[] = [];
	const globalEnumMap: RaiserFuncMap = { items: globalEnumMapItems };
	let funcIdx = 0;

	// Pass 1a: Collect functions + enums (must match Phase 2 compilation order)
	for (let mi = 0; mi < modules.length; mi += 1) {
		const pd = modules[mi].program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			const fnNode = unwrapToFuncDecl(pd.programStmts[i]);
			if (fnNode !== null) {
				const fd = fnNode.data as FunctionDeclData;
				const entry: RaiserFuncEntry = { name: fd.fnName, index: funcIdx };
				globalFuncMap.items.push(entry);
				funcIdx += 1;
			}
			const enumNode = unwrapToEnumDecl(pd.programStmts[i]);
			if (enumNode !== null) {
				const ed = enumNode.data as EnumDeclData;
				for (let ei = 0; ei < ed.enumMembers.length; ei += 1) {
					const val = (ed.enumValues !== null && ei < ed.enumValues.length) ? ed.enumValues[ei] : ei;
					const entry: RaiserFuncEntry = { name: `${ed.enumName}.${ed.enumMembers[ei]}`, index: val };
					globalEnumMap.items.push(entry);
				}
			}
		}
	}

	// Pass 1b: Collect classes (methods + constructors, must match Phase 2b order)
	for (let mi = 0; mi < modules.length; mi += 1) {
		const pd = modules[mi].program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			const classNode = unwrapToClassDecl(pd.programStmts[i]);
			if (classNode !== null) {
				const cd = classNode.data as ClassDeclData;
				let hasCtor = false;
				// Methods first (must match Phase 2b compilation order)
				for (let ci = 0; ci < cd.classBody.length; ci += 1) {
					if (cd.classBody[ci].kind === NodeKind.MethodDecl) {
						const md = cd.classBody[ci].data as MethodDeclData;
						const methodKey = `${cd.className}_${md.methodName}`;
						const mEntry: RaiserFuncEntry = { name: methodKey, index: funcIdx };
						globalFuncMap.items.push(mEntry);
						funcIdx += 1;
					}
				}
				// Constructor second
				for (let ci = 0; ci < cd.classBody.length; ci += 1) {
					if (cd.classBody[ci].kind === NodeKind.ConstructorDecl) {
						hasCtor = true;
						const ctorKey = cd.className + "_new";
						const cEntry: RaiserFuncEntry = { name: ctorKey, index: funcIdx };
						globalFuncMap.items.push(cEntry);
						funcIdx += 1;
					}
				}
				if (!hasCtor) {
					const ctorKey = cd.className + "_new";
					const cEntry: RaiserFuncEntry = { name: ctorKey, index: funcIdx };
					globalFuncMap.items.push(cEntry);
					funcIdx += 1;
				}
			}
		}
	}

	// --- Register builtins ---
	const builtinNames: string[] = ["defineConfig"];
	const builtinMapItems: RaiserBuiltinEntry[] = [];
	const builtinMap: RaiserBuiltinMap = { items: builtinMapItems };
	for (let bi = 0; bi < builtinNames.length; bi += 1) {
		const bName = builtinNames[bi];
		const bIdx = funcIdx;
		const bEntry: RaiserFuncEntry = { name: bName, index: bIdx };
		globalFuncMap.items.push(bEntry);
		const builtinEntry: RaiserBuiltinEntry = { name: bName, funcIdx: bIdx };
		builtinMap.items.push(builtinEntry);
		funcIdx += 1;
	}

	// --- Pass 2: Compile function bodies ---
	for (let mi = 0; mi < modules.length; mi += 1) {
		const pd = modules[mi].program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			const fnNode = unwrapToFuncDecl(pd.programStmts[i]);
			if (fnNode !== null) {
				const fd = fnNode.data as FunctionDeclData;
				const func = compileFuncBody(globalFuncMap, globalEnumMap, fd.fnName, fd.params, fd.fnBody, fd.params.length);
				functions.push(func);
			}
		}
	}

	// --- Pass 2b: Compile class methods and constructors ---
	for (let mi = 0; mi < modules.length; mi += 1) {
		const pd = modules[mi].program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			const classNode = unwrapToClassDecl(pd.programStmts[i]);
			if (classNode !== null) {
				const cd = classNode.data as ClassDeclData;
				let hasCtor = false;
				// Methods first (same order as Phase 1 collection)
				for (let ci = 0; ci < cd.classBody.length; ci += 1) {
					if (cd.classBody[ci].kind === NodeKind.MethodDecl) {
						const md = cd.classBody[ci].data as MethodDeclData;
						const methodName = `${cd.className}_${md.methodName}`;
						// md.methodParams already has "this" at index 0 (injected by collectPass)
						const func = compileFuncBody(globalFuncMap, globalEnumMap, methodName, md.methodParams, md.methodBody, md.methodParams.length);
						functions.push(func);
					}
				}
				// Constructor
				for (let ci = 0; ci < cd.classBody.length; ci += 1) {
					if (cd.classBody[ci].kind === NodeKind.ConstructorDecl) {
						hasCtor = true;
						const ctd = cd.classBody[ci].data as ConstructorDeclData;
						const func = compileClassConstructor(globalFuncMap, globalEnumMap, cd.className, cd.classBody, ctd.ctorParams, ctd.ctorBody);
						functions.push(func);
					}
				}
				if (!hasCtor) {
					const noParams: string[] = [];
					const func = compileClassConstructor(globalFuncMap, globalEnumMap, cd.className, cd.classBody, noParams, null as unknown as Node);
					functions.push(func);
				}
			}
		}
	}

	// --- Emit builtin stubs ---
	for (let bi = 0; bi < builtinNames.length; bi += 1) {
		const bName = builtinNames[bi];
		const stubCode: RaiserInstruction[] = [
			raiserABC(RaiserOpcode.Move, 0, 1, 0),
			raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		];
		const stubConsts: RaiserValue[] = [];
		const stubFunc = createRaiserFunction(bName, stubCode, stubConsts, 1, 0, 2);
		functions.push(stubFunc);
	}

	// --- Pass 3: Compile init functions for each module ---
	const initIndices: number[] = [];
	for (let mi = 0; mi < modules.length; mi += 1) {
		const pd = modules[mi].program.data as ProgramData;
		const s = createCompState();
		s.funcMap = globalFuncMap;
		s.enumMap = globalEnumMap;
		s.builtins = builtinMap;

		for (let i = 0; i < pd.programStmts.length; i += 1) {
			compileStmt(s, pd.programStmts[i]);
			resetTemps(s);
		}

		// Post-process: convert Halt → Ret (init functions return to caller)
		for (let j = 0; j < s.code.length; j += 1) {
			if (s.code[j].op === RaiserOpcode.Halt) {
				s.code[j] = raiserABC(RaiserOpcode.Ret, s.code[j].a, 0, 0);
			}
		}

		// Ensure init terminates with Ret
		if (s.code.length === 0) {
			const nilReg = allocReg(s);
			emitLoadConst(s, nilReg, raiserNil());
			emitRet(s, nilReg);
		} else {
			const lastOp = s.code[s.code.length - 1].op;
			if (lastOp !== RaiserOpcode.Ret) {
				const nilReg = allocReg(s);
				emitLoadConst(s, nilReg, raiserNil());
				emitRet(s, nilReg);
			}
		}

		const initFunc = createRaiserFunction("__init_" + mi, s.code, s.constants, 0, 0, s.maxRegSeen);
		functions.push(initFunc);
		initIndices.push(functions.length - 1);
	}

	// --- Create synthetic entry function ---
	// Calls all init functions in order, halts with last result
	const entryS = createCompState();
	let lastResultReg = 0;
	for (let ii = 0; ii < initIndices.length; ii += 1) {
		const destReg = allocReg(entryS);
		emitInst(entryS, raiserABC(RaiserOpcode.Call, destReg, initIndices[ii], 0));
		lastResultReg = destReg;
	}
	if (initIndices.length === 0) {
		emitLoadConst(entryS, 0, raiserNil());
	}
	emitInst(entryS, raiserABC(RaiserOpcode.Halt, lastResultReg, 0, 0));
	const entryFunc = createRaiserFunction("__entry", entryS.code, entryS.constants, 0, 0, entryS.maxRegSeen);
	functions.push(entryFunc);

	return createRaiserModule("project", functions, functions.length - 1);
}

// --- Public API ---
// Parse source code → compile to Raiser bytecode → execute → return context.
// The context holds lastResult (exit value) and lastOutput (console.log captures).

export function evalSource(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) return createContext();
	const mod = generateRaiser(parseResult.value);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

// --- Test helper ---

function evalRaiser(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		unreachable;
		return createContext();
	}
	const mod = generateRaiser(parseResult.value);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

// --- Tests ---
test "return number" {
	const ctx = evalRaiser("return 42;");
	assert ctx.lastResult.intVal === 42;
}

test "return addition" {
	const ctx = evalRaiser("return 2 + 3;");
	assert ctx.lastResult.intVal === 5;
}

test "return complex: 10 - 3 * 2 + 1" {
	const ctx = evalRaiser("return 10 - 3 * 2 + 1;");
	assert ctx.lastResult.intVal === 5;
}

test "return negation" {
	const ctx = evalRaiser("return -7;");
	assert ctx.lastResult.intVal === -7;
}

test "console.log captures output" {
	const ctx = evalRaiser("console.log(42);");
	assert ctx.lastOutput === "42\n";
}

test "console.log expression" {
	const ctx = evalRaiser("console.log(2 + 3);");
	assert ctx.lastOutput === "5\n";
}

test "(2 + 3) * 4 = 20" {
	const ctx = evalRaiser("return (2 + 3) * 4;");
	assert ctx.lastResult.intVal === 20;
}

test "84 / 2 = 42" {
	const ctx = evalRaiser("return 84 / 2;");
	assert ctx.lastResult.intVal === 42;
}

test "17 % 5 = 2" {
	const ctx = evalRaiser("return 17 % 5;");
	assert ctx.lastResult.intVal === 2;
}

test "const declaration and reference" {
	const ctx = evalRaiser("const x = 42; return x;");
	assert ctx.lastResult.intVal === 42;
}

test "variable arithmetic" {
	const ctx = evalRaiser("const a = 10; const b = 20; return a + b;");
	assert ctx.lastResult.intVal === 30;
}

test "let assignment" {
	const ctx = evalRaiser("let x = 1; x = 42; return x;");
	assert ctx.lastResult.intVal === 42;
}

test "chained variable ops" {
	const ctx = evalRaiser("const a = 5; const b = a * 2; const c = b + a; return c;");
	assert ctx.lastResult.intVal === 15;
}

test "greater than true" {
	const ctx = evalRaiser("return 5 > 3;");
	assert ctx.lastResult.intVal === 1;
}

test "greater than false" {
	const ctx = evalRaiser("return 3 > 5;");
	assert ctx.lastResult.intVal === 0;
}

test "equal true" {
	const ctx = evalRaiser("return 7 == 7;");
	assert ctx.lastResult.intVal === 1;
}

test "not equal" {
	const ctx = evalRaiser("return 5 != 3;");
	assert ctx.lastResult.intVal === 1;
}

test "less than or equal" {
	const ctx = evalRaiser("return 3 <= 3;");
	assert ctx.lastResult.intVal === 1;
}

test "if true branch" {
	const ctx = evalRaiser("if (5 > 3) { return 1; } else { return 0; }");
	assert ctx.lastResult.intVal === 1;
}

test "if false branch" {
	const ctx = evalRaiser("if (3 > 5) { return 1; } else { return 0; }");
	assert ctx.lastResult.intVal === 0;
}

test "if without else" {
	const ctx = evalRaiser("const x = 5; if (x > 10) { return 0; } return x;");
	assert ctx.lastResult.intVal === 5;
}

test "if with variable" {
	const ctx = evalRaiser("let r = 0; if (1 > 0) { r = 42; } return r;");
	assert ctx.lastResult.intVal === 42;
}

test "sum 1..5 = 15" {
	const ctx = evalRaiser("let sum = 0; let i = 1; while (i <= 5) { sum = sum + i; i = i + 1; } return sum;");
	assert ctx.lastResult.intVal === 15;
}

test "countdown" {
	const ctx = evalRaiser("let n = 10; while (n > 0) { n = n - 1; } return n;");
	assert ctx.lastResult.intVal === 0;
}

test "break exits loop" {
	const ctx = evalRaiser("let i = 0; while (i < 100) { if (i == 5) { break; } i = i + 1; } return i;");
	assert ctx.lastResult.intVal === 5;
}

test "continue skips iteration" {
	const ctx = evalRaiser("let sum = 0; let i = 0; while (i < 5) { i = i + 1; if (i == 3) { continue; } sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal === 12;
}

test "simple function call" {
	const ctx = evalRaiser("function add(a, b) { return a + b; } return add(3, 4);");
	assert ctx.lastResult.intVal === 7;
}

test "function no args" {
	const ctx = evalRaiser("function five() { return 5; } return five();");
	assert ctx.lastResult.intVal === 5;
}

test "nested calls: f(g(2))" {
	const ctx = evalRaiser("function triple(x) { return x * 3; } function inc(x) { return x + 1; } return inc(triple(2));");
	assert ctx.lastResult.intVal === 7;
}

test "nested calls: same function f(f(x))" {
	const ctx = evalRaiser("function dbl(x) { return x * 2; } return dbl(dbl(3));");
	assert ctx.lastResult.intVal === 12;
}

test "function with local variable" {
	const ctx = evalRaiser("function square(n) { const r = n * n; return r; } return square(6);");
	assert ctx.lastResult.intVal === 36;
}

test "recursive factorial" {
	const ctx = evalRaiser("function fact(n) { if (n <= 1) { return 1; } return n * fact(n - 1); } return fact(5);");
	assert ctx.lastResult.intVal === 120;
}

test "multiple function calls" {
	const ctx = evalRaiser("function add(a, b) { return a + b; } const x = add(10, 20); const y = add(x, 5); return y;");
	assert ctx.lastResult.intVal === 35;
}

test "string literal return" {
	const ctx = evalRaiser("return \"hello\";");
	assert ctx.lastResult.strVal === "hello";
}

test "console.log string" {
	const ctx = evalRaiser("console.log(\"world\");");
	assert ctx.lastOutput === "world\n";
}

test "number toString" {
	const ctx = evalRaiser("const x = 42; return x.toString();");
	assert ctx.lastResult.strVal === "42";
}

test "bool toString" {
	const ctx = evalRaiser("const b = true; return b.toString();");
	assert ctx.lastResult.strVal === "true";
}

test "toString in concat" {
	const ctx = evalRaiser("const x = 7; return \"n=\" + x.toString();");
	assert ctx.lastResult.strVal === "n=7";
}

test "true && value" {
	const ctx = evalRaiser("return 1 && 42;");
	assert ctx.lastResult.intVal === 42;
}

test "false && value" {
	const ctx = evalRaiser("return 0 && 42;");
	assert ctx.lastResult.intVal === 0;
}

test "false || value" {
	const ctx = evalRaiser("return 0 || 7;");
	assert ctx.lastResult.intVal === 7;
}

test "true || value" {
	const ctx = evalRaiser("return 1 || 99;");
	assert ctx.lastResult.intVal === 1;
}

test "logical in if condition" {
	const ctx = evalRaiser("const a = 1; const b = 2; if (a > 0 && b > 0) { return 1; } return 0;");
	assert ctx.lastResult.intVal === 1;
}

test "recursive fibonacci" {
	const ctx = evalRaiser("function fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } return fib(10);");
	assert ctx.lastResult.intVal === 55;
}

test "iterative fibonacci" {
	const ctx = evalRaiser("let a = 0; let b = 1; let i = 0; while (i < 10) { let tmp = a + b; a = b; b = tmp; i = i + 1; } return a;");
	assert ctx.lastResult.intVal === 55;
}

test "mutual recursion: isEven/isOdd" {
	const ctx = evalRaiser("function isEven(n) { if (n == 0) { return 1; } return isOdd(n - 1); } function isOdd(n) { if (n == 0) { return 0; } return isEven(n - 1); } return isEven(10);");
	assert ctx.lastResult.intVal === 1;
}

test "GCD" {
	const ctx = evalRaiser("function gcd(a, b) { if (b == 0) { return a; } return gcd(b, a % b); } return gcd(48, 18);");
	assert ctx.lastResult.intVal === 6;
}

test "nested loops: multiplication table sum" {
	const ctx = evalRaiser("let sum = 0; let i = 1; while (i <= 5) { let j = 1; while (j <= 5) { sum = sum + i * j; j = j + 1; } i = i + 1; } return sum;");
	assert ctx.lastResult.intVal === 225;
}

test "fibonacci with console.log" {
	const ctx = evalRaiser("function fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } let i = 0; while (i <= 6) { console.log(fib(i)); i = i + 1; }");
	assert ctx.lastOutput === "0\n1\n1\n2\n3\n5\n8\n";
}

test "true branch" {
	const ctx = evalRaiser("return 1 > 0 ? 42 : 99;");
	assert ctx.lastResult.intVal === 42;
}

test "false branch" {
	const ctx = evalRaiser("return 0 > 1 ? 42 : 99;");
	assert ctx.lastResult.intVal === 99;
}

test "nested ternary" {
	const ctx = evalRaiser("const x = 5; return x > 10 ? 1 : x > 3 ? 2 : 3;");
	assert ctx.lastResult.intVal === 2;
}

test "ternary in expression" {
	const ctx = evalRaiser("const a = 10; const b = 20; return (a > b ? a : b) + 1;");
	assert ctx.lastResult.intVal === 21;
}

test "postfix increment" {
	const ctx = evalRaiser("let x = 5; x++; return x;");
	assert ctx.lastResult.intVal === 6;
}

test "prefix increment" {
	const ctx = evalRaiser("let x = 5; ++x; return x;");
	assert ctx.lastResult.intVal === 6;
}

test "postfix returns old value" {
	const ctx = evalRaiser("let x = 5; let y = x++; return y;");
	assert ctx.lastResult.intVal === 5;
}

test "prefix returns new value" {
	const ctx = evalRaiser("let x = 5; let y = ++x; return y;");
	assert ctx.lastResult.intVal === 6;
}

test "decrement" {
	const ctx = evalRaiser("let x = 10; x--; x--; return x;");
	assert ctx.lastResult.intVal === 8;
}

test "increment in loop" {
	const ctx = evalRaiser("let sum = 0; let i = 0; while (i < 5) { sum = sum + i; i++; } return sum;");
	assert ctx.lastResult.intVal === 10;
}

test "executes at least once" {
	const ctx = evalRaiser("let x = 0; do { x = 42; } while (0 > 1); return x;");
	assert ctx.lastResult.intVal === 42;
}

test "loops until false" {
	const ctx = evalRaiser("let i = 0; do { i = i + 1; } while (i < 5); return i;");
	assert ctx.lastResult.intVal === 5;
}

test "break in do-while" {
	const ctx = evalRaiser("let i = 0; do { if (i == 3) { break; } i = i + 1; } while (i < 100); return i;");
	assert ctx.lastResult.intVal === 3;
}

test "export function with return" {
	const ctx = evalRaiser("export function triple(n) { return n * 3; } return triple(5);");
	assert ctx.lastResult.intVal === 15;
}

test "export function in expression" {
	const ctx = evalRaiser("export function add(a, b) { return a + b; } return add(10, add(3, 4));");
	assert ctx.lastResult.intVal === 17;
}

test "array literal and index access" {
	const ctx = evalRaiser("const arr = [10, 20, 30]; return arr[1];");
	assert ctx.lastResult.intVal === 20;
}

test "array length" {
	const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; return arr.length;");
	assert ctx.lastResult.intVal === 5;
}

test "array push and length" {
	const ctx = evalRaiser("const arr = [1, 2]; arr.push(3); return arr.length;");
	assert ctx.lastResult.intVal === 3;
}

test "array push and access" {
	const ctx = evalRaiser("const arr = []; arr.push(42); return arr[0];");
	assert ctx.lastResult.intVal === 42;
}

test "array index assignment" {
	const ctx = evalRaiser("const arr = [0, 0, 0]; arr[1] = 99; return arr[1];");
	assert ctx.lastResult.intVal === 99;
}

test "array iteration with while loop" {
	const ctx = evalRaiser("const arr = [10, 20, 30]; let sum = 0; let i = 0; while (i < arr.length) { sum = sum + arr[i]; i = i + 1; } return sum;");
	assert ctx.lastResult.intVal === 60;
}

test "array as function argument" {
	const ctx = evalRaiser("function sum(arr) { let s = 0; let i = 0; while (i < arr.length) { s = s + arr[i]; i = i + 1; } return s; } return sum([1, 2, 3, 4]);");
	assert ctx.lastResult.intVal === 10;
}

test "build array with push in loop" {
	const ctx = evalRaiser("const arr = []; let i = 0; while (i < 5) { arr.push(i * i); i = i + 1; } return arr[3];");
	assert ctx.lastResult.intVal === 9;
}

test "nested array access in expression" {
	const ctx = evalRaiser("const arr = [2, 3, 5]; return arr[0] * arr[1] + arr[2];");
	assert ctx.lastResult.intVal === 11;
}

test "object literal and field access" {
	const ctx = evalRaiser("const obj = { x: 10, y: 20 }; return obj.x;");
	assert ctx.lastResult.intVal === 10;
}

test "object field access second field" {
	const ctx = evalRaiser("const obj = { x: 10, y: 20 }; return obj.y;");
	assert ctx.lastResult.intVal === 20;
}

test "object field mutation" {
	const ctx = evalRaiser("const obj = { x: 1 }; obj.x = 99; return obj.x;");
	assert ctx.lastResult.intVal === 99;
}

test "object as function argument" {
	const ctx = evalRaiser("function sum(o) { return o.a + o.b; } return sum({ a: 3, b: 7 });");
	assert ctx.lastResult.intVal === 10;
}

test "object with computed values" {
	const ctx = evalRaiser("const a = 5; const b = 10; const obj = { sum: a + b }; return obj.sum;");
	assert ctx.lastResult.intVal === 15;
}

test "object in array" {
	const ctx = evalRaiser("const arr = [{ val: 1 }, { val: 2 }]; const item = arr[1]; return item.val;");
	assert ctx.lastResult.intVal === 2;
}

test "array in object" {
	const ctx = evalRaiser("const obj = { items: [1, 2, 3] }; return obj.items.length;");
	assert ctx.lastResult.intVal === 3;
}

test "string concat" {
	const ctx = evalRaiser("return \"hello\" + \" world\";");
	assert ctx.lastResult.strVal === "hello world";
}

test "string concat with variable" {
	const ctx = evalRaiser("const s = \"hi\"; return s + \"!\";");
	assert ctx.lastResult.strVal === "hi!";
}

test "string equality true" {
	const ctx = evalRaiser("return \"abc\" == \"abc\";");
	assert ctx.lastResult.intVal === 1;
}

test "string equality false" {
	const ctx = evalRaiser("return \"abc\" == \"def\";");
	assert ctx.lastResult.intVal === 0;
}

test "string inequality" {
	const ctx = evalRaiser("return \"abc\" != \"def\";");
	assert ctx.lastResult.intVal === 1;
}

test "string + number coercion" {
	const ctx = evalRaiser("return \"value: \" + 42;");
	assert ctx.lastResult.strVal === "value: 42";
}

test "function returning string" {
	const ctx = evalRaiser("function greet(name) { return \"Hello, \" + name; } return greet(\"world\");");
	assert ctx.lastResult.strVal === "Hello, world";
}

test "multi-concat chain" {
	const ctx = evalRaiser("return \"a\" + \"b\" + \"c\";");
	assert ctx.lastResult.strVal === "abc";
}

test "console.log string concat" {
	const ctx = evalRaiser("console.log(\"sum: \" + (2 + 3));");
	assert ctx.lastOutput === "sum: 5\n";
}

test "C-style for: sum 0..4" {
	const ctx = evalRaiser("let sum = 0; for (let i = 0; i < 5; i++) { sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal === 10;
}

test "C-style for: factorial" {
	const ctx = evalRaiser("let result = 1; for (let i = 1; i <= 5; i++) { result = result * i; } return result;");
	assert ctx.lastResult.intVal === 120;
}

test "C-style for: break" {
	const ctx = evalRaiser("let i = 0; for (i = 0; i < 100; i++) { if (i == 7) { break; } } return i;");
	assert ctx.lastResult.intVal === 7;
}

test "for-of: sum array elements" {
	const ctx = evalRaiser("const arr = [10, 20, 30]; let sum = 0; for (const x of arr) { sum = sum + x; } return sum;");
	assert ctx.lastResult.intVal === 60;
}

test "for-of: count elements" {
	const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; let count = 0; for (const x of arr) { count = count + 1; } return count;");
	assert ctx.lastResult.intVal === 5;
}

test "for-of: break early" {
	const ctx = evalRaiser("const arr = [1, 2, 3, 4, 5]; let sum = 0; for (const x of arr) { if (x > 3) { break; } sum = sum + x; } return sum;");
	assert ctx.lastResult.intVal === 6;
}

test "+=" {
	const ctx = evalRaiser("let x = 10; x += 5; return x;");
	assert ctx.lastResult.intVal === 15;
}

test "-=" {
	const ctx = evalRaiser("let x = 10; x -= 3; return x;");
	assert ctx.lastResult.intVal === 7;
}

test "*=" {
	const ctx = evalRaiser("let x = 4; x *= 3; return x;");
	assert ctx.lastResult.intVal === 12;
}

test "/=" {
	const ctx = evalRaiser("let x = 20; x /= 4; return x;");
	assert ctx.lastResult.intVal === 5;
}

test "%=" {
	const ctx = evalRaiser("let x = 17; x %= 5; return x;");
	assert ctx.lastResult.intVal === 2;
}

test "+= in loop" {
	const ctx = evalRaiser("let sum = 0; for (let i = 1; i <= 5; i++) { sum += i; } return sum;");
	assert ctx.lastResult.intVal === 15;
}

test "+= string concat" {
	const ctx = evalRaiser("let s = \"hello\"; s += \" world\"; return s;");
	assert ctx.lastResult.strVal === "hello world";
}

test "enum member access" {
	const ctx = evalRaiser("enum Color { Red, Green, Blue } return Color.Green;");
	assert ctx.lastResult.intVal === 1;
}

test "enum first member is 0" {
	const ctx = evalRaiser("enum Dir { Up, Down, Left, Right } return Dir.Up;");
	assert ctx.lastResult.intVal === 0;
}

test "enum last member" {
	const ctx = evalRaiser("enum Dir { Up, Down, Left, Right } return Dir.Right;");
	assert ctx.lastResult.intVal === 3;
}

test "enum in comparison" {
	const ctx = evalRaiser("enum Color { Red, Green, Blue } const c = Color.Blue; return c == 2;");
	assert ctx.lastResult.intVal === 1;
}

test "enum in if condition" {
	const ctx = evalRaiser("enum State { Off, On } const s = State.On; if (s == State.On) { return 42; } return 0;");
	assert ctx.lastResult.intVal === 42;
}

test "enum in function" {
	const ctx = evalRaiser("enum Color { Red, Green, Blue } function isBlue(c) { if (c == Color.Blue) { return 1; } return 0; } return isBlue(Color.Blue);");
	assert ctx.lastResult.intVal === 1;
}

test "enum arithmetic" {
	const ctx = evalRaiser("enum Op { Add, Sub, Mul } return Op.Mul * 10;");
	assert ctx.lastResult.intVal === 20;
}

test "string .length literal" {
	const ctx = evalRaiser("return \"hello\".length;");
	assert ctx.lastResult.intVal === 5;
}

test "string .length variable" {
	const ctx = evalRaiser("const s = \"abc\"; return s.length;");
	assert ctx.lastResult.intVal === 3;
}

test "empty string .length" {
	const ctx = evalRaiser("return \"\".length;");
	assert ctx.lastResult.intVal === 0;
}

test "charAt" {
	const ctx = evalRaiser("return \"hello\".charAt(1);");
	assert ctx.lastResult.strVal === "e";
}

test "charAt variable" {
	const ctx = evalRaiser("const s = \"world\"; return s.charAt(0);");
	assert ctx.lastResult.strVal === "w";
}

test "slice" {
	const ctx = evalRaiser("return \"hello world\".slice(0, 5);");
	assert ctx.lastResult.strVal === "hello";
}

test "slice variable" {
	const ctx = evalRaiser("const s = \"abcdef\"; return s.slice(2, 4);");
	assert ctx.lastResult.strVal === "cd";
}

test "string length in condition" {
	const ctx = evalRaiser("const s = \"abc\"; if (s.length > 2) { return 1; } return 0;");
	assert ctx.lastResult.intVal === 1;
}

test "non-capturing closure" {
	const ctx = evalRaiser("function lifted(_e) { return 42; } const f = { fn: lifted, env: {} }; return f();");
	assert ctx.lastResult.intVal === 42;
}

// Reference parity: environment parameter is LAST
test "closure with capture" {
	const ctx = evalRaiser("function lifted(y, _e) { return _e.x + y; } const e = { x: 5 }; const f = { fn: lifted, env: e }; return f(3);");
	assert ctx.lastResult.intVal === 8;
}

test "higher-order: makeAdder" {
	const ctx = evalRaiser("function liftedAdd(x, _e) { return _e.n + x; } function makeAdder(n) { return { fn: liftedAdd, env: { n: n } }; } const add5 = makeAdder(5); return add5(3);");
	assert ctx.lastResult.intVal === 8;
}

test "multiple captures" {
	const ctx = evalRaiser("function lifted(_e) { return _e.a + _e.b; } const f = { fn: lifted, env: { a: 3, b: 7 } }; return f();");
	assert ctx.lastResult.intVal === 10;
}

test "chained call: makeAdder(5)(3)" {
	const ctx = evalRaiser("function liftedAdd(x, _e) { return _e.n + x; } function makeAdder(n) { return { fn: liftedAdd, env: { n: n } }; } return makeAdder(5)(3);");
	assert ctx.lastResult.intVal === 8;
}

test "closure in loop" {
	const ctx = evalRaiser("function lifted(_e) { return _e.i; } let sum = 0; let i = 0; while (i < 5) { const f = { fn: lifted, env: { i: i } }; sum = sum + f(); i = i + 1; } return sum;");
	assert ctx.lastResult.intVal === 10;
}

test "closure returning closure" {
	const ctx = evalRaiser("function inner(_e2) { return _e2.x + _e2.y; } function outer(_e1) { return { fn: inner, env: { x: _e1.a, y: _e1.b } }; } const f = { fn: outer, env: { a: 3, b: 7 } }; const g = f(); return g();");
	assert ctx.lastResult.intVal === 10;
}

test "lambda-lifted capture pattern" {
	const ctx = evalRaiser("function lifted1(_envP) { return _envP.x; } const x = 99; const f = { fn: lifted1, env: { x: x } }; return f();");
	assert ctx.lastResult.intVal === 99;
}

test "lambda-lifted capture with args" {
	const ctx = evalRaiser("function lifted1(y, _envP) { return _envP.x + y; } const x = 10; const f = { fn: lifted1, env: { x: x } }; return f(32);");
	assert ctx.lastResult.intVal === 42;
}

test "lambda-lifted capture inside function" {
	const ctx = evalRaiser("function lifted1(_envP) { return _envP.x; } function make() { const x = 42; const f = { fn: lifted1, env: { x: x } }; return f(); } return make();");
	assert ctx.lastResult.intVal === 42;
}

test "lambda-lifted multiple captures" {
	const ctx = evalRaiser("function lifted1(_envP) { return _envP.a * _envP.b + _envP.c; } const a = 3; const b = 4; const c = 5; const f = { fn: lifted1, env: { a: a, b: b, c: c } }; return f();");
	assert ctx.lastResult.intVal === 17;
}

test "non-capturing closure pair with -1 sentinel" {
	const ctx = evalRaiser("function add(a, b) { return a + b; } const f = { fn: add, env: -1 }; return f(10, 20);");
	assert ctx.lastResult.intVal === 30;
}

test "object as return value" {
	const ctx = evalRaiser("return { root: \"src/main.ms\", target: \"native\" };");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/main.ms";
	const target = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "target");
	assert target === "native";
}

test "nested object config" {
	const ctx = evalRaiser("return { build: { target: \"native\", outDir: \"out\" } };");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const buildHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "build");
	assert buildHandle >= 0;
	const target = heapObjectGetString(ctx.objectHeap, buildHandle, "target");
	assert target === "native";
	const outDir = heapObjectGetString(ctx.objectHeap, buildHandle, "outDir");
	assert outDir === "out";
}

test "config with array of objects" {
	const ctx = evalRaiser("return { transforms: [{ name: \"var_hoist\" }] };");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const arrField = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "transforms");
	assert arrField.kind === RaiserValueKind.Array;
	assert heapArrayLen(ctx.arrayHeap, arrField.intVal) === 1;
	const elem = heapArrayGet(ctx.arrayHeap, arrField.intVal, 0);
	assert elem.kind === RaiserValueKind.Object;
	const name = heapObjectGetString(ctx.objectHeap, elem.intVal, "name");
	assert name === "var_hoist";
}

test "import defineConfig passthrough" {
	const ctx = evalRaiser("import { defineConfig } from \"std/build\"; return defineConfig({ root: \"src/main.ms\" });");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/main.ms";
}

test "full build.ms pattern" {
	const ctx = evalRaiser("import { defineConfig } from \"std/build\"; return defineConfig({ root: \"src/main.ms\", build: { target: \"native\" } });");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/main.ms";
	const buildHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "build");
	assert buildHandle >= 0;
	const target = heapObjectGetString(ctx.objectHeap, buildHandle, "target");
	assert target === "native";
}

test "export default object" {
	const ctx = evalRaiser("export default { root: \"src/main.ms\" };");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/main.ms";
}

test "export default with defineConfig" {
	const ctx = evalRaiser("import { defineConfig } from \"std/build\"; export default defineConfig({ root: \"app.ms\", build: { target: \"native\", outDir: \"out\" } });");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "app.ms";
	const buildHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "build");
	assert buildHandle >= 0;
	const outDir = heapObjectGetString(ctx.objectHeap, buildHandle, "outDir");
	assert outDir === "out";
}

test "real: neon/build.ms" {
	const src = "import { defineConfig, BuildOptions } from \"std/build\";\nexport default defineConfig({\n\troot: \"src/index.ms\",\n\tformat: {\n\t\ttabWidth: 4,\n\t\tuseTabs: true,\n\t\tsemi: true,\n\t},\n\tbuild: {\n\t\ttargets: [\n\t\t\t{ target: \"native\", outDir: \"build/c\" },\n\t\t\t{ target: \"js\", outDir: \"build/js\" },\n\t\t],\n\t},\n});";
	const ctx = evalRaiser(src);
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	// root
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/index.ms";
	// format.tabWidth
	const fmtHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "format");
	assert fmtHandle >= 0;
	const tabWidth = heapObjectGetField(ctx.objectHeap, fmtHandle, "tabWidth");
	assert tabWidth.intVal === 4;
	// build.targets array
	const buildHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "build");
	assert buildHandle >= 0;
	const targets = heapObjectGetField(ctx.objectHeap, buildHandle, "targets");
	assert targets.kind === RaiserValueKind.Array;
	assert heapArrayLen(ctx.arrayHeap, targets.intVal) === 2;
	// targets[0].target === "native"
	const t0 = heapArrayGet(ctx.arrayHeap, targets.intVal, 0);
	assert heapObjectGetString(ctx.objectHeap, t0.intVal, "target") === "native";
	assert heapObjectGetString(ctx.objectHeap, t0.intVal, "outDir") === "build/c";
	// targets[1].target === "js"
	const t1 = heapArrayGet(ctx.arrayHeap, targets.intVal, 1);
	assert heapObjectGetString(ctx.objectHeap, t1.intVal, "target") === "js";
	assert heapObjectGetString(ctx.objectHeap, t1.intVal, "outDir") === "build/js";
}

test "float arithmetic: add" {
	const ctx = evalRaiser("return 3.14 + 2.0;");
	assert ctx.lastResult.kind === RaiserValueKind.Float;
	assert ctx.lastResult.floatVal > 5.13;
	assert ctx.lastResult.floatVal < 5.15;
}

test "float arithmetic: mul" {
	const ctx = evalRaiser("return 1.5 * 4.0;");
	assert ctx.lastResult.kind === RaiserValueKind.Float;
	assert ctx.lastResult.floatVal === 6.0;
}

test "float arithmetic: sub" {
	const ctx = evalRaiser("return 10.5 - 3.5;");
	assert ctx.lastResult.kind === RaiserValueKind.Float;
	assert ctx.lastResult.floatVal === 7.0;
}

test "float arithmetic: div" {
	const ctx = evalRaiser("return 7.5 / 2.5;");
	assert ctx.lastResult.kind === RaiserValueKind.Float;
	assert ctx.lastResult.floatVal === 3.0;
}

test "float arithmetic: neg" {
	const ctx = evalRaiser("return -3.14;");
	assert ctx.lastResult.kind === RaiserValueKind.Float;
	assert ctx.lastResult.floatVal < -3.13;
	assert ctx.lastResult.floatVal > -3.15;
}

test "float comparison: less than" {
	const ctx = evalRaiser("if (1.5 < 2.5) { return 1; } return 0;");
	assert ctx.lastResult.intVal === 1;
}

test "float comparison: greater than" {
	const ctx = evalRaiser("if (3.14 > 2.71) { return 1; } return 0;");
	assert ctx.lastResult.intVal === 1;
}

test "real: void/build.ms" {
	const src = "import { defineConfig } from \"std/build\";\nexport default defineConfig({\n\troot: \"src/index.ms\",\n\tbuild: {\n\t\ttarget: \"native\",\n\t\toutDir: \"out\",\n\t\toutFile: \"void\",\n\t\toptimize: \"debug\",\n\t},\n});";
	const ctx = evalRaiser(src);
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	// root
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/index.ms";
	// build.target
	const buildHandle = heapObjectGetObjectHandle(ctx.objectHeap, ctx.lastResult.intVal, "build");
	assert buildHandle >= 0;
	const target = heapObjectGetString(ctx.objectHeap, buildHandle, "target");
	assert target === "native";
	// build.outDir
	const outDir = heapObjectGetString(ctx.objectHeap, buildHandle, "outDir");
	assert outDir === "out";
	// build.outFile
	const outFile = heapObjectGetString(ctx.objectHeap, buildHandle, "outFile");
	assert outFile === "void";
	// build.optimize
	const optimize = heapObjectGetString(ctx.objectHeap, buildHandle, "optimize");
	assert optimize === "debug";
}

test "bitwise AND" {
	const ctx = evalRaiser("return 5 & 3;");
	assert ctx.lastResult.intVal === 1;
}

test "bitwise OR" {
	const ctx = evalRaiser("return 5 | 3;");
	assert ctx.lastResult.intVal === 7;
}

test "bitwise XOR" {
	const ctx = evalRaiser("return 5 ^ 3;");
	assert ctx.lastResult.intVal === 6;
}

test "bitwise NOT" {
	const ctx = evalRaiser("return ~0;");
	assert ctx.lastResult.intVal === -1;
}

test "shift left" {
	const ctx = evalRaiser("return 1 << 3;");
	assert ctx.lastResult.intVal === 8;
}

test "shift right" {
	const ctx = evalRaiser("return 8 >> 2;");
	assert ctx.lastResult.intVal === 2;
}

test "complex bitwise" {
	const ctx = evalRaiser("return (0xFF & 0x0F) | 0x30;");
	assert ctx.lastResult.intVal === 63;
}

test "obj.field += value" {
	const ctx = evalRaiser("let obj = { x: 10 }; obj.x += 5; return obj.x;");
	assert ctx.lastResult.intVal === 15;
}

test "obj.field -= value" {
	const ctx = evalRaiser("let obj = { x: 10 }; obj.x -= 3; return obj.x;");
	assert ctx.lastResult.intVal === 7;
}

test "arr[i] += value" {
	const ctx = evalRaiser("let arr = [10, 20, 30]; arr[1] += 5; return arr[1];");
	assert ctx.lastResult.intVal === 25;
}

test "arr[i] *= value" {
	const ctx = evalRaiser("let arr = [1, 2, 3]; arr[0] *= 10; return arr[0];");
	assert ctx.lastResult.intVal === 10;
}

test "constructor and field access" {
	const ctx = evalRaiser("class Point { constructor(x, y) { this.x = x; this.y = y; } } const p = Point_new(3, 4); return p.x;");
	assert ctx.lastResult.intVal === 3;
}

test "second field access" {
	const ctx = evalRaiser("class Point { constructor(x, y) { this.x = x; this.y = y; } } const p = Point_new(3, 4); return p.y;");
	assert ctx.lastResult.intVal === 4;
}

test "method returning constant" {
	const ctx = evalRaiser("class Box { answer() { return 42; } } const b = Box_new(); return b.answer();");
	assert ctx.lastResult.intVal === 42;
}

test "method accessing this field" {
	const ctx = evalRaiser("class Box { constructor(v) { this.val = v; } getVal() { return this.val; } } const b = Box_new(42); return b.getVal();");
	assert ctx.lastResult.intVal === 42;
}

test "method with params" {
	const ctx = evalRaiser("class Calc { constructor(base) { this.base = base; } add(n) { return this.base + n; } } const c = Calc_new(10); return c.add(5);");
	assert ctx.lastResult.intVal === 15;
}

test "closure env mutation" {
	const ctx = evalRaiser("function inc(_e) { _e.n = _e.n + 1; } const obj = { n: 0 }; const f = { fn: inc, env: obj }; f(); return obj.n;");
	assert ctx.lastResult.intVal === 1;
}

test "method mutation single call" {
	const ctx = evalRaiser("class Counter { constructor(n) { this.n = n; } inc() { this.n = this.n + 1; return this.n; } } const c = Counter_new(0); return c.inc();");
	assert ctx.lastResult.intVal === 1;
}

test "method mutation two calls" {
	const ctx = evalRaiser("class Counter { constructor(n) { this.n = n; } inc() { this.n = this.n + 1; return this.n; } } const c = Counter_new(0); c.inc(); return c.inc();");
	assert ctx.lastResult.intVal === 2;
}

test "two objects in function" {
	const ctx = evalRaiser("function mk(n) { const self = {}; const other = {}; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "two fields on one object in function" {
	const ctx = evalRaiser("function mk(n) { const self = {}; self.x = 1; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "one-way link only" {
	const ctx = evalRaiser("function mk(n) { const self = {}; const cl = {}; self.other = cl; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "reverse link only" {
	const ctx = evalRaiser("function mk(n) { const self = {}; const cl = {}; cl.ref = self; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "forward obj link then read" {
	const ctx = evalRaiser("function mk(n) { const self = {}; const cl = {}; self.other = cl; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "forward obj link return const" {
	const ctx = evalRaiser("function mk() { const self = {}; const cl = {}; self.other = cl; self.n = 42; return self.n; }  return mk();");
	assert ctx.lastResult.intVal === 42;
}

test "field name get on single obj" {
	const ctx = evalRaiser("function mk() { const a = {}; a.get = 42; return a.get; } return mk();");
	assert ctx.lastResult.intVal === 42;
}

test "field name get store obj no bidir" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; a.get = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "field name get store obj bidir" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.get = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "field name gett bidir" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.gett = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "field name ge bidir" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.ge = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "field name set bidir" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.set = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "bidir link print each step" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; a.n = 10; console.log(a.n); b.ref = a; console.log(a.n); a.other = b; console.log(a.n); return a.n; } return mk();");
	assert ctx.lastOutput === "10\n10\n10\n";
}

test "set n before bidir then return n" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; a.n = 42; b.ref = a; a.other = b; return a.n; } return mk();");
	assert ctx.lastResult.intVal === 42;
}

test "set n after bidir then return n" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.other = b; a.n = 42; return a.n; } return mk();");
	assert ctx.lastResult.intVal === 42;
}

test "bidir then return 1 no field" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.other = b; return 1; } return mk();");
	assert ctx.lastResult.intVal === 1;
}

test "set n after bidir return const" {
	const ctx = evalRaiser("function mk() { const a = {}; const b = {}; b.ref = a; a.other = b; a.n = 42; return 99; } return mk();");
	assert ctx.lastResult.intVal === 99;
}

test "bidir top level" {
	const ctx = evalRaiser("const self = {}; const cl = {}; cl.ref = self; self.get = cl; self.n = 5; return self.n;");
	assert ctx.lastResult.intVal === 5;
}

test "two objects linked" {
	const ctx = evalRaiser("function mk(n) { const self = {}; const cl = {}; cl.ref = self; self.get = cl; self.n = n; return self; } const c = mk(5); return c.n;");
	assert ctx.lastResult.intVal === 5;
}

test "class direct field with methods" {
	const ctx = evalRaiser("class Box { constructor(v) { this.val = v; } getVal() { return this.val; } } const b = Box_new(42); return b.val;");
	assert ctx.lastResult.intVal === 42;
}

test "no explicit constructor" {
	const ctx = evalRaiser("class Greeter { greet() { return 42; } } const g = Greeter_new(); return g.greet();");
	assert ctx.lastResult.intVal === 42;
}

test "method calling another method" {
	const ctx = evalRaiser("class Math { dbl(x) { return x * 2; } quad(x) { return this.dbl(this.dbl(x)); } } const m = Math_new(); return m.quad(3);");
	assert ctx.lastResult.intVal === 12;
}

test "class instance as value" {
	const ctx = evalRaiser("class Pair { constructor(a, b) { this.a = a; this.b = b; } sum() { return this.a + this.b; } } const p = Pair_new(3, 7); const result = p.sum(); return result;");
	assert ctx.lastResult.intVal === 10;
}
