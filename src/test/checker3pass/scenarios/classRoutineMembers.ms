import { checkOnly } from "../helpers";

const PRELUDE = "class Animal { name: string = \"a\"; speak(): string { return \"animal\"; } }\n"
	+ "class Dog extends Animal { bark(): string { return \"w\"; } speak(): string { return \"dog\"; } }\n";

function errorsOf(body: string): string {
	return checkOnly(PRELUDE + body).errors.join("\n");
}

test "a base instance is refused where a subclass with another method is expected" {
	const text = errorsOf("function one(a: Dog): string { return a.bark(); }\nconst an: Animal = new Animal();\none(an);\n");
	assert text.contains("property 'bark' is missing in type 'Animal' but required in type 'Dog'"),
		"a missing method must fail the checker: " + text;
}

test "an unrelated class lacking a method or an accessor of the target is refused" {
	const method = errorsOf("class Cat { name: string = \"c\"; purr(): string { return \"p\"; } }\n"
		+ "function one(c: Cat): string { return c.purr(); }\none(new Animal());\n");
	assert method.contains("property 'purr' is missing in type 'Animal' but required in type 'Cat'"),
		"an unrelated class without the method must fail: " + method;
	const accessor = errorsOf("class Tag { name: string = \"t\"; get label(): string { return this.name; } }\n"
		+ "class Plain { name: string = \"p\"; }\nfunction one(t: Tag): string { return t.label; }\none(new Plain());\n");
	assert accessor.contains("property 'label' is missing in type 'Plain' but required in type 'Tag'"),
		"an unrelated class without the accessor must fail: " + accessor;
}

test "an interface value is refused where a class with a method is expected" {
	const text = errorsOf("interface Named { name: string; }\nfunction one(d: Dog): string { return d.bark(); }\n"
		+ "const n: Named = new Animal();\none(n);\n");
	assert text.contains("property 'bark' is missing in type 'Named' but required in type 'Dog'"),
		"an interface value must fail: " + text;
}

test "a class instance is refused where a generic class instance with a method is expected" {
	const text = errorsOf("class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }\n"
		+ "class Plain { v: int32 = 1; }\nfunction one(b: Box<int32>): int32 { return b.get(); }\none(new Plain());\n");
	assert text.contains("property 'get' is missing in type 'Plain' but required in type 'Box<int32>'"),
		"a generic class target must fail: " + text;
}

test "a subclass, a class with every routine, and a class into an interface still check" {
	for (const body of ["function one(a: Animal): string { return a.speak(); }\none(new Dog());\n",
		"class Far extends Dog { }\nfunction one(a: Animal): string { return a.speak(); }\none(new Far());\n",
		"class Quiet { name: string = \"q\"; }\nfunction one(q: Quiet): string { return q.name; }\none(new Dog());\n",
		"interface Named { name: string; }\nfunction one(n: Named): string { return n.name; }\none(new Dog());\n",
		"class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }\n"
			+ "class Sub extends Box<int32> { }\nfunction one(b: Box<int32>): int32 { return b.get(); }\none(new Sub(2));\n"]) {
		const text = errorsOf(body);
		assert text == "", "a relation the routines do not break must check: " + text;
	}
}
