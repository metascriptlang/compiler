import { hasError, strictErrorCount } from "./helpers";
import { compileToC, compileToJS, compileToJSBare } from "../helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

const box = "class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }\n"
	+ "interface I { v: int32; }\n";

const readBack = "function f(u: unknown): int32 { return (u as Box<int32>).get(); }\n"
	+ "function g(u: unknown): string { return (u as Box<string>).v; }\n"
	+ "console.log(f(new Box<int32>(7)).toString() + g(new Box<string>(\"s\")));";

test "genericInstanceCast: a generic class instance is a checked target" {
	assert accepts(box + "function f(u: unknown): int32 { return (u as Box<int32>).v; }");
}

test "genericInstanceCast: an interface is still not a target" {
	assert hasError(box + "function f(u: unknown): int32 { return (u as I).v; }", "only a class has a runtime identity");
}

test "genericInstanceCast: instanceof refuses a generic class without its type arguments" {
	assert hasError(box + "function f(u: unknown): boolean { return u instanceof Box; }", "instanceof cannot test the generic class Box");
}

test "genericInstanceCast: a target written with a type parameter is checked in each instance" {
	assert accepts(box + "function f<T>(u: unknown): T { return (u as Box<T>).v; }\nconsole.log(f<int32>(new Box<int32>(1)).toString());");
}

test "genericInstanceCast: C tests each instantiation against its own type info" {
	const r = compileToC(box + readBack);
	assert r.ok;
	assert r.value.contains("msObjDownConv("), "the conversion is tested";
	assert r.value.contains("__int32TypeInfo)"), "the int32 instance names its type info";
	assert r.value.contains("__stringTypeInfo)"), "the string instance names its type info";
}

test "genericInstanceCast: JS declares an instance that is only ever a cast target" {
	const r = compileToJSBare(box + "function f(u: unknown): int32 { return (u as Box<int32>).v; }\nconsole.log(\"cast only\");");
	assert r.ok;
	const at = r.value.indexOf("instanceof Box_");
	assert at >= 0, "the cast tests a mangled class";
	const name = r.value.slice(at + 11, r.value.indexOf(")", at));
	assert r.value.contains("class " + name + " "), "the tested class is declared: " + name;
}

test "genericInstanceCast: a cast to the same instance is not tested" {
	const r = compileToC(box + "function f(b: Box<int32>): int32 { return (b as Box<int32>).v; }\nconsole.log(f(new Box<int32>(1)).toString());");
	assert r.ok;
	assert !r.value.contains("msObjDownConv(");
}

test "genericInstanceCast: JS constructs and tests the instance class" {
	const r = compileToJSBare(box + readBack);
	assert r.ok;
	assert r.value.contains("new Box_"), "new builds a mangled class";
	assert !r.value.contains("new Box(") && !r.value.contains("new Box__Z"), "new never builds the erased class";
	assert r.value.contains("instanceof Box_"), "the test names a mangled class";
	assert !r.value.contains("instanceof Box)") && !r.value.contains("instanceof Box__Z"), "the test never names the erased class";
	assert r.value.contains("is not Box<int32>"), "the message shows the instance";
}

test "genericInstanceCast: instanceof narrows a union to the members that instantiate the generic class" {
	assert accepts("async function two(): Promise<number> { return 2; }\nfunction f(r: Promise<number> | number): string {\n\tif (r instanceof Promise) { return \"pending\"; }\n\treturn (r + 1).toString();\n}\n"), "a Promise member";
	assert accepts(box + "function f(x: Box<string> | Box<number> | int32): int32 {\n\tif (x instanceof Box) { return 0; }\n\treturn x + 1;\n}\n"), "two instances are both selected";
	assert accepts(box + "class Pair<U> extends Box<U> { w: U; constructor(v: U, w: U) { super(v); this.w = w; } }\nfunction f(x: Pair<int32> | string): int32 {\n\tif (x instanceof Box) { return x.w; }\n\treturn x.length;\n}\n"), "a subclass instance is selected";
	assert hasError(box + "function f(x: Box<string> | Box<number> | int32): int32 {\n\tif (x instanceof Box) { return x + 1; }\n\treturn 0;\n}\n", "operator '+' cannot be applied"), "the true branch holds no number";
}

test "genericInstanceCast: instanceof refuses a union whose ancestor member could hide an instance" {
	assert hasError("class Base { n: int32 = 0; }\nclass Sub<T> extends Base { v: T; constructor(v: T) { super(); this.v = v; } }\nfunction f(x: Base | string): boolean { return x instanceof Sub; }\n", "instanceof cannot test the generic class Sub");
}
