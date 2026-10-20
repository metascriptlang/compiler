import { checkOnly } from "../helpers";

const FD = "struct Fd { n: int32; }\nfunction onDestroy(this f: Fd): void { }\n";

test "a struct hook called by name or as a method is refused at both calls" {
	const text = checkOnly(FD + "function run(): void { const f: Fd = { n: 3 }; onDestroy(f); f.onDestroy(); }").errors.join("\n");
	assert text.contains("'onDestroy' is a lifecycle hook");
	assert text.split("is a lifecycle hook").length == 3;
}

test "a class hook called on a value or through super is refused" {
	const text = checkOnly("class Base { onDestroy(): void { } }\nclass Derived extends Base { onDestroy(): void { super.onDestroy(); } }\nfunction run(d: Derived): void { d.onDestroy(); }").errors.join("\n");
	assert text.split("is a lifecycle hook").length == 3;
	assert text.contains("the base class hook runs on its own");
}

test "every hook name is refused, a copy hook included" {
	const text = checkOnly("struct P { n: int32; }\nfunction onCopy(this ref d: P, y: P): void { }\nfunction run(): void { let a: P = { n: 1 }; const b: P = { n: 2 }; onCopy(a, b); }").errors.join("\n");
	assert text.contains("'onCopy' is a lifecycle hook");
}

test "a hook taken as a value, by name or from a class value, is refused" {
	const text = checkOnly(FD + "class Conn { onDestroy(): void { } }\nfunction run(c: Conn): void { const close = onDestroy; const end = c.onDestroy; }").errors.join("\n");
	assert text.split("it has no value to keep and call later").length == 3;
}

test "a plain function that only shares a hook's name is still callable" {
	const result = checkOnly("function onDestroy(n: int32): int32 { return n; }\nconst a = onDestroy(3);");
	assert result.errors.length == 0;
}
