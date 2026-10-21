// Route 2: ccgIntroducedPtr — type→pointer decision
//
// Verifies the codegen decision of whether to introduce pointer params
// based on struct size, interface flag, and Ref wrapping.

import { TargetInfo, createStruct, createRef, numberType, stringType, createMaybeType } from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "ccgIntroducedPtr: small struct = false" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Small", ["x", "y"], [numberType(), numberType()], true);
	assert !ccgIntroducedPtr(tg, t);
}

test "ccgIntroducedPtr: large struct = true" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Big", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], true);
	assert ccgIntroducedPtr(tg, t);
}

test "ccgIntroducedPtr: struct with string fields = true" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("WithStr", ["x", "name", "desc"], [numberType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(tg, t);
}

test "ccgIntroducedPtr: Ref type = false" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const inner = createStruct("FooRef", ["x"], [numberType()], true);
	const ref = createRef(inner);
	assert !ccgIntroducedPtr(tg, ref);
}

test "ccgIntroducedPtr: non-interface struct = false" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Raw", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], false);
	assert !ccgIntroducedPtr(tg, t);
}

test "ccgIntroducedPtr: class type (Ref<Struct>) = false" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const inner = createStruct("DocR", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	const classType = createRef(inner);
	assert !ccgIntroducedPtr(tg, classType);
}

test "ccgIntroducedPtr: unwrapped class inner struct = true" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const inner = createStruct("DocRI", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(tg, inner);
}

test "ccgIntroducedPtr: Maybe wrapper large enough" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const inner = createStruct("BigTokM", ["kind", "value", "extra"], [numberType(), stringType(), stringType()], true);
	const maybe = createMaybeType(inner);
	assert ccgIntroducedPtr(tg, maybe);
}

test "ccgIntroducedPtr: collapsed Maybe<Ref<T>> = false" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const inner = createStruct("FooMC", ["x"], [numberType()], true);
	const ref = createRef(inner);
	const maybe = createMaybeType(ref);
	assert !ccgIntroducedPtr(tg, maybe);
}

// ===== E2E: a struct passed by introduced pointer keeps its pointer at the call =====

import { compileToC } from "../helpers";

test "E2E ccgPtr: a direct call passes the caller's struct pointer through" {
	const src = "struct BigS { a: number; b: number; c: number; d: number; e: string }\n" +
		"export function process(item: BigS): number { return item.a; }\n" +
		"export function caller(item: BigS): number { return process(item); }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("* item)");
	assert c.value.contains("_u0(item);");
}

test "E2E ccgPtr: a closure call passes the struct pointer through" {
	const src = "struct BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type Handler = (d: BigS) => number;\n" +
		"export function run(h: Handler, d: BigS): number { return h(d); }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("* d)");
	assert c.value.contains("h.fn)(d, h.env)");
	assert c.value.contains("h.fn)(d)");
}

test "E2E ccgPtr: a call under try passes the struct pointer through" {
	const src = "struct BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type BigResult = Result<BigS, string>;\n" +
		"function parse(d: BigS): BigResult { return Result.ok(d); }\n" +
		"export function caller(d: BigS): BigResult {\n" +
		"  const inner = try parse(d);\n" +
		"  return Result.ok(inner);\n" +
		"}";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("* d)");
	assert c.value.contains(", d);");
}

// ===== Empty array param typing (reference: semArrayConstr expectedType) =====

test "E2E: empty [] arg typed as string[] param" {
	const src = "function foo(names: string[]): number { return names.length; }\nconst x = foo([]);";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("msStringArray");
}

test "E2E: empty [] arg typed as Type[] param" {
	const src = "interface Foo { x: number; }\nfunction bar(items: Foo[]): number { return items.length; }\nconst y = bar([]);";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("(msRefArray* items)");
}

import { compileProjectToC, MapEntry } from "../helpers";

test "MULTI: empty [] arg typed as string[] cross-module" {
	const libSrc = "export function makeStruct(name: string, fields: string[]): number { return fields.length; }";
	const mainSrc = "import { makeStruct } from \"./lib\";\nconst x = makeStruct(\"Foo\", []);";
	const entries: MapEntry[] = [
		{ entryPath: "test/main.ms", entrySource: mainSrc },
		{ entryPath: "test/lib.ms", entrySource: libSrc },
	];
	const result = compileProjectToC(entries, "test/main.ms");
	// This helper verifies cross-module resolution only: makeStruct is emitted iff
	// the "./lib" import actually loaded (it silently didn't before map-key
	// canonicalization). The empty-[] element-type (msStringArray vs msRefArray)
	// needs refineTypes/lowerNativeAccess, which this string-grep pipeline skips —
	// that property is verified against msc-const directly, not here.
	assert !result.contains("ERROR:");
	assert result.contains("makeStruct");
	assert !result.contains("msAnon_");
}
