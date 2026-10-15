import { parseSource } from "../../parser/statements/validation";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { NodeKind, ProgramData, VariableDeclData, TypeAssertionData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { typeDisplayName } from "../../checker/types";
import { compileToC, refusedOnEveryBackend } from "../helpers";

function convertedOperationType(source: string, name: string): string {
	resetBuildState();
	const pr = parseSource(source);
	if (!pr.ok) return "parse failed";
	checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, preludeContextFor("", ".cms"));
	for (const stmt of (pr.value.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.VariableDecl || (stmt.data as VariableDeclData).declName != name) continue;
		const init = (stmt.data as VariableDeclData).initializer;
		if (init == null || init.kind != NodeKind.TypeAssertion) return "not a conversion";
		const operand = (init.data as TypeAssertionData).asExpr;
		if (operand.kind != NodeKind.BinaryExpr || operand.nodeType == null) return "converts no operation";
		return typeDisplayName(operand.nodeType);
	}
	return "no " + name;
}

test "asPrecedence: the operation before as runs in its operands' type" {
	const product = convertedOperationType("const count: int32 = 3;\nconst size: int32 = 4;\nconst bytes = count * size as int64;", "bytes");
	assert product == "int32", product;
	const calls = convertedOperationType("function f(): int32 { return 3; }\nfunction g(): int32 { return 4; }\nconst total = f() + g() as int64;", "total");
	assert calls == "int32", calls;
	const sum = convertedOperationType("const x: float64 = 0.1;\nconst y: float64 = 0.2;\nconst s = x + y as float32;", "s");
	assert sum == "float64", sum;
}

test "asPrecedence: a comparison before as is a boolean, which converts to no number" {
	const compared = refusedOnEveryBackend("const a: int32 = 1;\nconst b: int32 = 2;\nconst c = a < b as int32;\nconsole.log(`${c}`);", "a boolean is not a number");
	assert compared == "", compared;
	const flag = refusedOnEveryBackend("const on: boolean = true;\nconsole.log(`${on as number}`);", "a boolean is not a number");
	assert flag == "", flag;
}

test "asPrecedence: an operator after a + b as T that would have taken b is a syntax error" {
	const r = compileToC("const a: int32 = 1;\nconst b: int32 = 2;\nconst c: int32 = 3;\nconst d = a + b as int64 * c;\nconsole.log(`${d}`);");
	assert !r.ok && r.error.includes("Unexpected token: *"), r.ok ? "accepted" : r.error;
}

test "asPrecedence: a < after an as type that never closes is a syntax error, not a swallowed statement" {
	const keyword = refusedOnEveryBackend("const a: int32 = 1;\nconst b: int32 = 2;\nconst r = a as int32 < b;\nconsole.log(`${r}`);", "Expected '>' to close the type arguments");
	assert keyword == "", keyword;
	const reference = refusedOnEveryBackend("type T = int32;\nconst a: int32 = 1;\nconst b: int32 = 2;\nif (a as T < b) { console.log(\"lt\"); }", "Expected '>' to close the type arguments");
	assert reference == "", reference;
}
