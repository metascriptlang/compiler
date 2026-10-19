import { checkOnly } from "../helpers";

const PRELUDE = "class Base { k: int32 = 1; }\n"
	+ "class Derived extends Base { s: string = \"hi\"; }\n"
	+ "class Foo { n: int32 = 3; }\n";

const NARROW_INSIDE = "and narrow it inside";

function errorsOf(body: string): string {
	return checkOnly(PRELUDE + body).errors.join("\n");
}

test "an override taking a subclass of the base parameter is refused at its declaration" {
	const text = errorsOf("class A { m(x: Base): void { } }\nclass B extends A { m(d: Derived): void { } }\n");
	assert text.contains("Method 'B.m(d: Derived): void' overrides 'A.m(x: Base): void', but parameter 'd' takes Derived and a call through 'A' passes it Base; declare the parameter Base " + NARROW_INSIDE),
		"a narrowed parameter must fail the checker: " + text;
}

test "an override taking a type unrelated to the base parameter is refused" {
	const text = errorsOf("class A { m(x: Base): void { } }\nclass B extends A { m(f: Foo): void { } }\n");
	assert text.contains("parameter 'f' takes Foo and a call through 'A' passes it Base"), "an unrelated parameter must fail the checker: " + text;
}

test "an override dropping null from the base parameter is refused" {
	const text = errorsOf("class A { m(x: Base | null): void { } }\nclass B extends A { m(x: Base): void { } }\n");
	assert text.contains("parameter 'x' takes Base and a call through 'A' passes it Base | null"), "dropping null must fail the checker: " + text;
}

test "an override two levels below is related to the nearest method it overrides" {
	const viaMiddle = errorsOf("class A { m(x: Base): void { } }\nclass B extends A { m(x: Base): void { } }\nclass C extends B { m(d: Derived): void { } }\n");
	assert viaMiddle.contains("overrides 'B.m(x: Base): void'") && viaMiddle.contains(NARROW_INSIDE), "C.m must be related to B.m: " + viaMiddle;
	const skipping = errorsOf("class A { m(x: Base): void { } }\nclass B extends A { }\nclass C extends B { m(d: Derived): void { } }\n");
	assert skipping.contains("overrides 'A.m(x: Base): void'") && skipping.contains(NARROW_INSIDE), "C.m must be related to A.m through B: " + skipping;
}

test "an override returning a supertype of the base result is refused, written or inferred" {
	const written = errorsOf("class A { m(): Derived { return new Derived(); } }\nclass B extends A { m(): Base { return new Base(); } }\n");
	assert written.contains("it returns Base and a call through 'A' expects Derived"), "a widened return must fail the checker: " + written;
	const inferred = errorsOf("class A { m(): Derived { return new Derived(); } }\nclass B extends A { m() { return new Base(); } }\n");
	assert inferred.contains("it returns Base and a call through 'A' expects Derived"), "an inferred widened return must fail the checker: " + inferred;
}

test "an override adding a parameter without a default is refused" {
	const text = errorsOf("class A { m(x: Base): void { } }\nclass B extends A { m(x: Base, y: int32): void { } }\n");
	assert text.contains("parameter 'y' has no default and a call through 'A' never passes it"), "an extra required parameter must fail the checker: " + text;
}

test "an override with the same, a wider or a numerically wider parameter checks" {
	for (const body of ["class A { m(x: Base): void { } }\nclass B extends A { m(d: Base): void { } }\n",
		"class A { m(x: Derived): void { } }\nclass B extends A { m(d: Base): void { } }\n",
		"class A { m(x: Base): void { } }\nclass B extends A { m(d: Base | null): void { } }\n",
		"class A { m(x: int32): void { } }\nclass B extends A { m(x: number): void { } }\n"]) {
		const text = errorsOf(body);
		assert text == "", "a parameter that takes what the base passes must check: " + text;
	}
}

test "an override with a narrower or numerically wider result, or a result where the base returns void, checks" {
	for (const body of ["class A { m(): Base { return new Base(); } }\nclass B extends A { m(): Derived { return new Derived(); } }\n",
		"class A { m(): Base { return new Base(); } }\nclass B extends A { m() { return new Derived(); } }\n",
		"class A { m(): number { return 1.5; } }\nclass B extends A { m(): int32 { return 2; } }\n",
		"class A { m(): void { } }\nclass B extends A { m(): int32 { return 1; } }\n"]) {
		const text = errorsOf(body);
		assert text == "", "a result the base's caller can read must check: " + text;
	}
}
