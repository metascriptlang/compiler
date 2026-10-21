// E2E: Classes and Interfaces → C output
// Classes are instantiated so DCE keeps them.

import { compileToC, compileToCWithStd } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { formatNode } from "../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../compiler/fmt/options";


test "E2E C: class with new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Foo");
}

test "E2E C: interface struct" {
	const src = "interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("struct Point");
}

test "E2E C: constructor allocates with msAllocTyped" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	// Constructor uses heap allocation for class types
	assert c.value.contains("msAllocTyped(sizeof(Foo__");
}

const DOWN_NODES = "class BaseNode { id: int32 = 0; }\n" +
	"class NativeNode extends BaseNode { view: string = \"native\"; }\n";

function checkedConversions(code: string): int32 {
	let count = 0 as int32;
	let at = code.indexOf("msObjDownConv(");
	while (at >= 0) {
		count += 1;
		at = code.indexOf("msObjDownConv(", at + 1);
	}
	return count;
}

test "E2E C: a conversion out of unknown and a base-to-derived conversion are each checked" {
	const c = compileToC(DOWN_NODES +
		"function f(u: unknown): string { return (u as NativeNode).view; }\n" +
		"function g(b: BaseNode): string { return (b as NativeNode).view; }\n" +
		"console.log(f(new NativeNode()) + g(new NativeNode()));");
	assert c.ok;
	const checked = checkedConversions(c.value);
	assert checked == 2, "got " + checked.toString();
}

test "E2E C: an upcast is not checked" {
	const c = compileToC(DOWN_NODES +
		"function f(n: NativeNode): BaseNode { return n as BaseNode; }\n" +
		"console.log(f(new NativeNode()).id.toString());");
	assert c.ok;
	assert checkedConversions(c.value) == 0;
}

test "E2E C: an alias of a class is that class as a conversion target, down and up" {
	const c = compileToC(DOWN_NODES +
		"type Native = NativeNode;\ntype Base = BaseNode;\n" +
		"function f(u: unknown): string { return (u as Native).view; }\n" +
		"function g(n: NativeNode): Base { return n as Base; }\n" +
		"console.log(f(new NativeNode()) + g(new NativeNode()).id.toString());");
	assert c.ok;
	const checked = checkedConversions(c.value);
	assert checked == 1, "got " + checked.toString();
}

function accessorError(src: string): string {
	const c = compileToC(src);
	return c.ok ? "compiled" : c.error;
}

test "E2E C: writing a getter-only accessor is refused" {
	assert accessorError("class C { get n(): int32 { return 1; } }\nconst c = new C();\nc.n = 2;").contains("Cannot assign to 'n' because it is a read-only property");
	assert accessorError("struct V2 { x: float32; get sum(): float32 { return this.x; } }\nlet v: V2 = { x: 1.0 };\nv.sum = 2.0;").contains("Cannot assign to 'sum'");
}

test "E2E C: an accessor named like a field is a duplicate identifier" {
	assert accessorError("class C { n: int32 = 0; get n(): int32 { return 1; } }\nconst c = new C();\nconsole.log(c.n);").contains("Duplicate identifier 'n'");
	assert accessorError("struct V2 { x: float32; get x(): float32 { return 1.0; } }\nconst v: V2 = { x: 1.0 };").contains("Duplicate identifier 'x'");
}

test "E2E C: a readonly struct or interface field is written only by its literal" {
	assert accessorError("interface N { readonly x: float32; }
const n: N = { x: 1.5 };
n.x = 2.0;").contains("cannot assign to 'x' because it is a read-only property");
	assert accessorError("struct P { readonly id: int32; v: int32; }
function bump(ref p: P): void { p.id += 1; }").contains("cannot assign to 'id' because it is a read-only property");
	assert accessorError("struct P { private readonly id: int32; v: int32; }
let p: P = { id: 1, v: 2 };
p.v = 3;
console.log(p.v);") == "compiled";
}

test "E2E C: a decorated accessor stays an accessor and keeps its name" {
	const deco = "import { Node, ClassMethodDecoratorContext } from \"std/meta\";\nmacro logged(value: Node, context: ClassMethodDecoratorContext): Node { return value; }\n";
	const renamer = "import { Node, ClassMethodDecoratorContext } from \"std/meta\";\nmacro rename(value: Node, context: ClassMethodDecoratorContext): Node { value.methodName = \"get_m\"; return value; }\n";
	assert compileToCWithStd(deco + "class C { @logged get n(): int32 { return 1; } }\nconsole.log(new C().n);").ok;
	assert compileToCWithStd(deco + "class C { private _n: int32 = 0; get n(): int32 { return this._n; } @logged set n(v: int32) { this._n = v; } }\nconst c = new C();\nc.n = 2;").ok;
	const renamed = compileToCWithStd(renamer + "class C { @rename get n(): int32 { return 1; } }");
	assert !renamed.ok;
	if (!renamed.ok) assert renamed.error.contains("decorator 'rename' on a getter 'n' must return a getter 'n' or nothing, got getter 'm'");
}

function stdError(src: string): string {
	const c = compileToCWithStd(src);
	return c.ok ? "compiled" : c.error;
}

test "E2E C: a decorated struct getter stays the struct's getter" {
	const deco = "import { Node, ClassGetterDecoratorContext } from \"std/meta\";\nmacro logged(value: Node, context: ClassGetterDecoratorContext): Node { return value; }\n";
	const tell = "import { Node, NodeKind, ClassGetterDecoratorContext } from \"std/meta\";\nmacro tell(value: Node, context: ClassGetterDecoratorContext): void { context.addInitializer({ kind: NodeKind.ExprStmt, line: 1, column: 0, expr: { kind: NodeKind.NumberLiteral, line: 1, column: 0, value: 1.0, isFloat: true } }); }\n";
	const renamer = "import { Node, ClassGetterDecoratorContext } from \"std/meta\";\nmacro rename(value: Node, context: ClassGetterDecoratorContext): Node { value.fnName = \"get_m\"; return value; }\n";
	assert stdError(deco + "struct V2 { x: float32; @logged get sum(): float32 { return this.x; } }\nconst v: V2 = { x: 1.0 };\nconsole.log(v.sum);") == "compiled";
	assert stdError(tell + "struct V2 { x: float32; @tell get sum(): float32 { return this.x; } }").contains("addInitializer on struct getter 'sum' is not supported");
	assert stdError(renamer + "struct V2 { x: float32; @rename get sum(): float32 { return this.x; } }").contains("decorator 'rename' on a getter 'sum' must return a getter 'sum' or nothing, got getter 'm'");
	assert stdError(deco + "struct V2 { x: float32; @logged set sum(v: float32) {} }").contains("a struct takes getters only");
	const mark = "import { Node, NodeKind, ClassGetterDecoratorContext, metadataSet } from \"std/meta\";\nmacro mark(value: Node, context: ClassGetterDecoratorContext): void { metadataSet(context.metadata, \"k\", { kind: NodeKind.NumberLiteral, line: 1, column: 0, value: 1.0, isFloat: true }); }\n";
	assert stdError(mark + "struct V2 { x: float32; @mark get sum(): float32 { return this.x; } }").contains("context.metadata on struct getter 'sum' is not supported");
}

test "E2E C: an accessor field is a typed instance field of a class" {
	assert accessorError("class C { accessor n: int32 = 1; }\nconst c = new C();\nc.n += 1;\nconsole.log(c.n);") == "compiled";
	assert accessorError("class C { static accessor n: int32 = 1; }").contains("Accessor field 'n' at line 1 cannot be static");
	assert accessorError("class C { readonly accessor n: int32 = 1; }").contains("'accessor' modifier cannot be used with 'readonly' modifier");
	assert accessorError("class C { accessor n = 1; }").contains("Accessor field 'n' at line 1 needs a type annotation");
	assert accessorError("class C { accessor n(): int32 { return 1; } }").contains("Accessor field 'n' at line 1 cannot be a method");
	assert accessorError("actor A { accessor n: int32 = 1; }").contains("an accessor field belongs to a class, not to an actor");
	assert accessorError("class C { accessor: int32 = 1; }\nconst c = new C();\nconsole.log(c.accessor);") == "compiled";
}

test "E2E C: a compound assignment to an accessor through a call receiver is refused" {
	assert accessorError("class C { get n(): int32 { return 1; } set n(v: int32) {} }\nfunction make(): C { return new C(); }\nmake().n += 1;").contains("needs a receiver that is a name or a field path");
}

test "E2E C: an accessor's shape is checked where it is declared" {
	assert accessorError("class C { get n(v: int32): int32 { return v; } }").contains("Getter 'n' at line 1 cannot take parameters");
	assert accessorError("class C { set n(): void {} }").contains("Setter 'n' at line 1 must take exactly one parameter");
	assert accessorError("class C { static get n(): int32 { return 1; } }").contains("cannot be static");
	assert accessorError("struct V2 { x: float32; set y(v: float32) {} }").contains("a struct takes getters only");
}

function fmtSource(source: string): string {
	const parsed = parseSource(source);
	if (!parsed.ok) return "";
	const opts = defaultFormatOptions();
	opts.source = source;
	const printed = formatNode(parsed.value, opts);
	return printed.ok ? printed.value : "";
}

test "fmt: class accessors print back as get and set" {
	const out = fmtSource("class C {\n\tprivate _n: int32 = 0;\n\tget n(): int32 { return this._n; }\n\tset n(v: int32) { this._n = v; }\n}\n");
	assert out.contains("get n(): int32"), out;
	assert out.contains("set n(v: int32)"), out;
	assert !out.contains("get_n"), out;
}

test "fmt: an accessor field prints back as written" {
	const out = fmtSource("class C {\n\tprivate accessor n: int32 = 1;\n\t@paint accessor x: float32 = 0.0;\n}\n");
	assert out.contains("private accessor n: int32 = 1;"), out;
	assert out.contains("accessor x: float32 = 0.0;"), out;
	assert !out.contains("accessor_storage"), out;
}

test "fmt: struct getters print back inside their struct, in source order" {
	const out = fmtSource("export struct V {\n\tx: float32;\n\tget a(): float32 { return this.x; }\n\ty: float32;\n\tget b(): float32 { return this.y; }\n}\nconst k = 1;\n");
	const a = out.indexOf("get a(): float32");
	const y = out.indexOf("y: float32;");
	const b = out.indexOf("get b(): float32");
	const close = out.indexOf("const k");
	assert a > 0 && a < y && y < b && b < close, out;
	assert !out.contains("function get_"), out;
}

test "fmt: a decorated struct getter prints back with its decorators inside its struct" {
	const out = fmtSource("export struct V {\n\tx: float32;\n\t@twice get a(): float32 { return this.x; }\n\t@keep\n\tget b(): float32 { return this.x; }\n}\nconst k = 1;\n");
	const a = out.indexOf("@twice get a(): float32");
	const keep = out.indexOf("@keep\n");
	const b = out.indexOf("get b(): float32");
	const close = out.indexOf("const k");
	assert a > 0 && a < keep && keep < b && b < close, out;
	assert !out.contains("function get_"), out;
}
