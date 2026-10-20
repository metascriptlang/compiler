import { checkOnly } from "../helpers";

const PRELUDE = "class Dog { name: string = \"d\"; speak(): string { return \"woof\"; } }\n"
	+ "class Robot { name: string = \"r\"; speak(): string { return \"beep\"; } }\n";

function errorsOf(body: string): string {
	return checkOnly(PRELUDE + body).errors.join("\n");
}

const NOT_A_DOG = "Robot is not a Dog: classes convert only along `extends`; make Robot extend Dog, or type the slot with an interface";

test "an unrelated class with every member of the slot class is refused at a declaration and an argument" {
	const declared = errorsOf("const d: Dog = new Robot();\n");
	assert declared.contains(NOT_A_DOG), "a declaration must refuse it: " + declared;
	const argument = errorsOf("function talk(d: Dog): string { return d.speak(); }\ntalk(new Robot());\n");
	assert argument.contains(NOT_A_DOG), "an argument must refuse it: " + argument;
	const nullable = errorsOf("const d: Dog | null = new Robot();\n");
	assert nullable.contains(NOT_A_DOG), "a nullable slot must refuse it: " + nullable;
}

test "an unrelated class is refused when only fields match, when both declare the member private, and through its subclass" {
	const fields = checkOnly("class Dog { a: int32 = 1; }\nclass Robot { a: int32 = 3; }\nconst d: Dog = new Robot();\n").errors.join("\n");
	assert fields.contains(NOT_A_DOG), "a field-only class must be refused: " + fields;
	const priv = checkOnly("class Dog { private n: int32 = 1; }\nclass Robot { private n: int32 = 2; }\nconst d: Dog = new Robot();\n").errors.join("\n");
	assert priv.contains(NOT_A_DOG), "separate private declarations must be refused: " + priv;
	const kid = errorsOf("class Kid extends Robot { }\nconst d: Dog = new Kid();\n");
	assert kid.contains("Kid is not a Dog: classes convert only along `extends`"), "a subclass of an unrelated class must be refused: " + kid;
}

test "an unrelated generic class instance is refused" {
	const text = checkOnly("class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n"
		+ "class Crate<T> { v: T; constructor(v: T) { this.v = v; } }\nconst b: Box<int32> = new Crate<int32>(5);\n").errors.join("\n");
	assert text.contains("Crate<int32> is not a Box<int32>: classes convert only along `extends`"), "a generic class must be refused: " + text;
}

test "a base instance where a subclass is expected names the run-time test" {
	const text = errorsOf("class Pup extends Dog { }\nfunction one(p: Pup): string { return p.name; }\none(new Dog());\n");
	assert text.contains("not every Dog is a Pup: test it with `instanceof Pup`, or convert it with `as Pup`"), "a downcast must name instanceof: " + text;
}

test "a subclass, a generic subclass, a nullable slot and an interface slot still check" {
	for (const body of ["class Pup extends Dog { }\nclass Far extends Pup { }\nconst d: Dog = new Far();\n",
		"class Pup extends Dog { }\nconst d: Dog | null = new Pup();\n",
		"interface Named { name: string; }\nconst n: Named = new Robot();\n",
		"class Box<T> { v: T; constructor(v: T) { this.v = v; } }\nclass Sub<T> extends Box<T> { }\nconst b: Box<int32> = new Sub<int32>(5);\n"]) {
		const text = errorsOf(body);
		assert text == "", "a relation along extends or into an interface must check: " + text;
	}
}
