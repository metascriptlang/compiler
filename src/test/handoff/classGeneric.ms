// Route 4: Generic class — definition + instantiation
//
// Verifies: class Box<T> method types resolve T from class-level generics,
// method types have correct params after this-injection,
// extension lowering produces correct mangled call,
// and new Box<number>(42) instantiates correctly.

import { TypeKind } from "../../ast/node";
import { checkSource, fullPipeline, errorCount } from "./helpers";
import { compileToC } from "../helpers";
import { lookupSymbol } from "../../checker/symbol";

test "checker: generic class method has this param" {
	const ctx = checkSource("class Box<T> { value: T; get(): T { return this.value; } }");
	assert ctx !== null;
	// Methods live in the extension registry keyed by (receiver, name), not as flat
	// module symbols; codegen later lowers them to Box_get free functions.
	let found = false;
	for (const m of ctx.extensionRegistry.methods) {
		if (m.receiverTypeName === "Box" && m.methodName === "get") {
			found = true;
			assert m.sym !== null;
			assert m.sym.symbolType.kind === TypeKind.Function;
			assert m.sym.symbolType.typeNames.length >= 1;
			assert m.sym.symbolType.typeNames[0] === "this";
		}
	}
	assert found;
}

test "checker: generic class method with T param has 2 params" {
	const ctx = checkSource("class Box<T> { value: T; set(v: T): void { this.value = v; } }");
	assert ctx !== null;
	let found = false;
	for (const m of ctx.extensionRegistry.methods) {
		if (m.receiverTypeName === "Box" && m.methodName === "set") {
			found = true;
			assert m.sym !== null;
			assert m.sym.symbolType.kind === TypeKind.Function;
			// params: [this: Box, v: T]
			assert m.sym.symbolType.typeChildren.length === 2;
		}
	}
	assert found;
}

test "checker: non-generic class method works" {
	const n = errorCount("class Dog { name: string; bark(): string { return this.name; } }\nconst d = new Dog(\"Rex\");\nconst s = d.bark();");
	assert n === 0;
}

test "E2E C: non-generic class method compiles" {
	const src = "class Dog { name: string; constructor(n: string) { this.name = n; } bark(): string { return this.name; } }\nconst d = new Dog(\"Rex\");\nconsole.log(d.bark());";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.indexOf("Dog_bark") >= 0;
}

test "E2E C: static class method compiles" {
	const src = "class Util { static greet(): string { return \"hi\"; } }\nconsole.log(Util.greet());";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.indexOf("Util_greet") >= 0;
}

// ===== Extension method receiver (BEFORE generic tests) =====

test "E2E C: charCodeAt receiver BEFORE generics" {
	const src = "const p = \"hello\";\nconst c = p.charCodeAt(0);";
	const result = compileToC(src);
	assert result.ok;
	// Receiver p is first arg (module-level const, so its C name is path-mangled).
	assert result.value.indexOf("msStringCharCodeAt(p") >= 0;
}

// ===== Generic Class Instantiation =====

test "checker: new Box<number>(42) no errors" {
	const n = errorCount("class Box<T> { value: T; }\nconst b = new Box<number>(42);");
	assert n === 0;
}

test "checker: generic class field type is substituted" {
	const ctx = checkSource("class Box<T> { value: T; }\nconst b = new Box<number>(42);");
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "b");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
	const inner = sym.symbolType.typeReturn;
	assert inner !== null;
	// Checker keeps the generic name + type-arg children; name mangling (Box__number)
	// happens in the monomorphize pass, which checkSource does not run.
	assert inner.typeName === "Box";
	assert inner.typeChildren.length === 1;
	assert inner.typeChildren[0].kind === TypeKind.Number;
}

test "checker: two different instantiations no errors" {
	const n = errorCount("class Pair<T> { a: T; b: T; }\nconst x = new Pair<number>(1, 2);\nconst y = new Pair<string>(\"a\", \"b\");");
	assert n === 0;
}

test "E2E C: generic class instantiation compiles" {
	const src = "class Box<T> { value: T; }\nconst b = new Box<number>(42);";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.indexOf("Box__number") >= 0;
}

// ===== Regression: extension method receiver not dropped =====

test "E2E C: charCodeAt keeps receiver after generic class" {
	const src = "const p = \"hello\";\nconst c = p.charCodeAt(0);";
	const result = compileToC(src);
	assert result.ok;
	// Must keep receiver p as first arg — NOT msStringCharCodeAt(0). The C name of
	// the module-level const p is path-mangled, so match the receiver prefix only.
	assert result.value.indexOf("msStringCharCodeAt(p") >= 0;
}

test "E2E C: trim keeps receiver" {
	const src = "const s = \"  hi  \";\nconst t = s.trim();";
	const result = compileToC(src);
	assert result.ok;
	// Must keep receiver s — NOT msStringTrim(). Module-level const s is path-mangled,
	// so match the receiver prefix only.
	assert result.value.indexOf("msStringTrim(s") >= 0;
}

// ===== Multi-param generics =====

test "checker: two-param generic class no errors" {
	const n = errorCount("class KV<K, V> { key: K; val: V; }\nconst m = new KV<string, number>(\"a\", 1);");
	assert n === 0;
}

test "checker: two-param generic field types substituted" {
	const ctx = checkSource("class KV<K, V> { key: K; val: V; }\nconst m = new KV<string, number>(\"a\", 1);");
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "m");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
	const inner = sym.symbolType.typeReturn;
	assert inner !== null;
	// Checker keeps the generic name + type-arg children; mangling to KV__string,number
	// happens in the monomorphize pass, which checkSource does not run.
	assert inner.typeName === "KV";
	assert inner.typeChildren.length === 2;
	assert inner.typeChildren[0].kind === TypeKind.String;
	assert inner.typeChildren[1].kind === TypeKind.Number;
}

test "E2E C: two-param generic compiles" {
	const src = "class KV<K, V> { key: K; val: V; }\nconst m = new KV<string, number>(\"a\", 1);";
	const result = compileToC(src);
	assert result.ok;
	// C mangler converts "," to "X" and adds trailing "_"
	assert result.value.indexOf("KV__string") >= 0;
}

// Regression test for the generic wrapper + Map.set monomorphize bug
// lives in examples/testGenericWrapper.ms — it exercises the full compile
// pipeline (msc run) which triggers the on-demand instantiation path that
// compileToC's test harness doesn't reach. The 3-part fix is in:
//   src/monomorphize/clone.ms     — copy typeArg in Mono mode
//   src/checker/instantiate.ms    — substitute typeArg in substNodeLocal
//   src/checker/checkExprPass.ms  — resolveGenericNewExpr prefers node.typeArg
// Reverting any of the three causes the smoke test to fail with:
//   set__...u0(Map__unknown_unknown*, void*, void*)
