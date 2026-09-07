// Route 15c: Checker — a bound type param must accept every later argument

import { strictErrorCount, hasError } from "./helpers";

const EQ2 = "function eq2<T>(a: T, b: T): boolean { return a == b; }\n";
const ID2 = "function id2<T>(a: T, b: T): T { return a; }\n";
const TPL_ID2 = "template id2<T>(a: T, b: T): T { return a; }\n";
const TPL_T2 = "template t2<T, U>(a: T, b: U, c: T): T { return a; }\n";
const CLASSES = "class Animal { name: string = \"\"; }\nclass Dog extends Animal { breed: string = \"\"; }\nfunction pair<T>(a: T, b: T): T { return a; }\nconst dog = new Dog();\nconst animal = new Animal();\n";

// ===== Rejected: a later argument contradicts the binding =====

test "second argument contradicting an inferred T is rejected" {
	assert hasError(EQ2 + "const c = eq2(\"s\", 3);", "Argument type mismatch in 'eq2' arg 1: got int32, expected string");
}

test "the diagnostic names the argument that bound T" {
	assert hasError(EQ2 + "const c = eq2(\"s\", 3);", "'T' was bound by argument 0");
}

test "a body without any operator still reports the mismatch" {
	assert hasError(ID2 + "const c = id2(\"s\", 3);", "Argument type mismatch in 'id2' arg 1");
}

test "struct bound first rejects a string second" {
	const src = "struct P { m: int32; }\nfunction pick<T>(a: T, b: T): T { return a; }\nconst p: P = { m: 1 };\nconst c = pick(p, \"s\");";
	assert hasError(src, "Argument type mismatch in 'pick' arg 1: got string, expected P");
}

test "T bound through an array element rejects a bad scalar" {
	const src = "function first<T>(xs: T[], v: T): T { return v; }\nconst a: int32[] = [1, 2];\nconst c = first(a, \"s\");";
	assert hasError(src, "Argument type mismatch in 'first' arg 1: got string, expected int32");
}

test "narrowing float64 into an int32 binding is rejected" {
	const src = "function pick<T>(a: T, b: T): T { return a; }\nconst c = pick(1, 2.5);";
	assert hasError(src, "Argument type mismatch in 'pick' arg 1: got float64, expected int32");
}

test "a supertype argument does not fit a subtype binding" {
	assert hasError(CLASSES + "const c = pair(dog, animal);", "Argument type mismatch in 'pair' arg 1: got Animal, expected Dog");
}

// ===== Rejected: the same rule inside template expansion =====

test "template argument contradicting an inferred T is rejected" {
	assert hasError(TPL_ID2 + "const c = id2(\"s\", 3);", "Argument type mismatch in 'id2' arg 1: got int32, expected string");
}

test "template reports the third argument against the first binding" {
	assert hasError(TPL_T2 + "const c = t2(\"s\", 1, 2);", "Argument type mismatch in 't2' arg 2: got int32, expected string");
}

// ===== Accepted =====

test "matching arguments infer T without complaint" {
	assert strictErrorCount(EQ2 + "const c = eq2(\"s\", \"t\");") == 0;
}

test "explicit type args keep working" {
	assert strictErrorCount(EQ2 + "const c = eq2<string>(\"s\", \"t\");") == 0;
}

test "widening int32 into a float64 binding is accepted" {
	const src = "function pick<T>(a: T, b: T): T { return a; }\nconst c = pick(2.5, 1);";
	assert strictErrorCount(src) == 0;
}

test "a subtype argument fits a supertype binding" {
	assert strictErrorCount(CLASSES + "const c = pair(animal, dog);") == 0;
}

test "a lambda typed from the formal does not report a conflict" {
	const src = "function mapAll<T, U>(xs: T[], f: (x: T) => U): U[] {\n\tconst out: U[] = [];\n\tfor (const x of xs) out.push(f(x));\n\treturn out;\n}\nconst a: int32[] = [1, 2];\nconst r = mapAll(a, (x: int32): string => \"v\");";
	assert strictErrorCount(src) == 0;
}

test "a template with matching arguments expands cleanly" {
	assert strictErrorCount(TPL_ID2 + "const c = id2(\"s\", \"t\");") == 0;
}
