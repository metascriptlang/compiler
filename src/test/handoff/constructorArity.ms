// Checker -> codegen: a `new` whose arguments the class cannot take stops in the checker.
// Before, the count reached codegen: "new with N argument(s) ... reached codegen unlowered"
// for a class that takes none, and a C compiler error for a constructor of another arity.

import { hasError, strictErrorCount } from "./helpers";

const TOO_MANY = "Too many arguments to 'new ";
const TOO_FEW = "Too few arguments to 'new ";

test "a class with no constructor and no field takes no argument" {
	assert hasError("class Foo {}\nconst f = new Foo(1);", TOO_MANY + "Foo': expected at most 0, got 1");
	assert strictErrorCount("class Foo {}\nconst a = new Foo();\nconst b = new Foo;") == 0;
}

test "a class with no constructor takes at most one argument per field" {
	const pre = "class Pair { x: number = 0; y: number = 0; }\n";
	assert strictErrorCount(pre + "const a = new Pair(1);\nconst b = new Pair(1, 2);") == 0;
	assert hasError(pre + "const c = new Pair(1, 2, 3);", TOO_MANY + "Pair': expected at most 2, got 3");
}

test "a struct counts its fields the same way" {
	const pre = "struct P { x: number; y: number; }\n";
	assert strictErrorCount(pre + "const a = new P(1, 2);") == 0;
	assert hasError(pre + "const c = new P(1, 2, 3);", TOO_MANY + "P': expected at most 2, got 3");
}

test "a constructor with another parameter count refuses both directions" {
	const pre = "class Bar { n: number = 0; constructor(a: number, b: number) { this.n = a + b; } }\n";
	assert strictErrorCount(pre + "const a = new Bar(1, 2);") == 0;
	assert hasError(pre + "const f = new Bar(1);", TOO_FEW + "Bar': expected at least 2, got 1");
	assert hasError(pre + "const f = new Bar;", TOO_FEW + "Bar': expected at least 2, got 0");
	assert hasError(pre + "const f = new Bar(1, 2, 3);", TOO_MANY + "Bar': expected at most 2, got 3");
}

test "a constructor without parameters takes no argument" {
	const pre = "class Zero { n: number = 0; constructor() { this.n = 1; } }\n";
	assert strictErrorCount(pre + "const a = new Zero();") == 0;
	assert hasError(pre + "const f = new Zero(1);", TOO_MANY + "Zero': expected at most 0, got 1");
}

test "an optional or defaulted parameter may be left out, and no more than declared may be given" {
	const opt = "class Opt { n: number = 0; constructor(a: number, b?: number) { this.n = a; } }\n";
	assert strictErrorCount(opt + "const a = new Opt(1);\nconst b = new Opt(1, 2);") == 0;
	assert hasError(opt + "const f = new Opt();", TOO_FEW + "Opt': expected at least 1, got 0");
	assert hasError(opt + "const f = new Opt(1, 2, 3);", TOO_MANY + "Opt': expected at most 2, got 3");
	const def = "class Def { n: number = 0; constructor(a: number, b: number = 5) { this.n = a + b; } }\n";
	assert strictErrorCount(def + "const a = new Def(1);\nconst b = new Def(1, 2);") == 0;
	assert hasError(def + "const f = new Def();", TOO_FEW + "Def': expected at least 1, got 0");
	assert hasError(def + "const f = new Def(1, 2, 3);", TOO_MANY + "Def': expected at most 2, got 3");
}

test "a defaulted parameter before a required one is still required" {
	const pre = "class Lead { n: number = 0; constructor(a: number = 1, b: number) { this.n = a + b; } }\n";
	assert strictErrorCount(pre + "const a = new Lead(1, 2);") == 0;
	assert hasError(pre + "const f = new Lead(1);", TOO_FEW + "Lead': expected at least 2, got 1");
}

test "a rest parameter takes any count past the required ones" {
	const pre = "class Many { n: number = 0; constructor(a: number, ...rest: number[]) { this.n = a + rest.length; } }\n";
	assert strictErrorCount(pre + "const a = new Many(1);\nconst b = new Many(1, 2, 3, 4);") == 0;
	assert hasError(pre + "const f = new Many();", TOO_FEW + "Many': expected at least 1, got 0");
}

test "an inherited constructor is counted from the class that declares it" {
	const pre = "class Base { u: number = 0; constructor(u: number, w: string = \"p\") { this.u = u; } }\nclass Sub extends Base { n: number = 5; }\nclass Leaf extends Sub { }\n";
	assert strictErrorCount(pre + "const a = new Sub(7);\nconst b = new Sub(7, \"q\");\nconst c = new Leaf(7);") == 0;
	assert hasError(pre + "const f = new Sub();", TOO_FEW + "Sub': expected at least 1, got 0");
	assert hasError(pre + "const f = new Sub(7, \"q\", 3);", TOO_MANY + "Sub': expected at most 2, got 3");
	assert hasError(pre + "const f = new Leaf(7, \"q\", 3);", TOO_MANY + "Leaf': expected at most 2, got 3");
}

test "a generic class counts the constructor of its declaration" {
	const pre = "class Box<T> { v: T; w: number; constructor(v: T, w: number = 3) { this.v = v; this.w = w; } }\n";
	assert strictErrorCount(pre + "const a = new Box<number>(1);\nconst b = new Box<string>(\"s\", 4);") == 0;
	assert hasError(pre + "const f = new Box<number>();", TOO_FEW + "Box': expected at least 1, got 0");
	assert hasError(pre + "const f = new Box<number>(1, 2, 3);", TOO_MANY + "Box': expected at most 2, got 3");
}

test "a spread argument has no count the checker can compare" {
	const pre = "class Many { n: number = 0; constructor(...rest: number[]) { this.n = rest.length; } }\nconst xs: number[] = [1, 2];\n";
	assert strictErrorCount(pre + "const a = new Many(...xs);") == 0;
}

test "an extern class keeps the arguments of its native constructor" {
	assert strictErrorCount("extern class Native {}\nconst n = new Native(1, 2);") == 0;
}
