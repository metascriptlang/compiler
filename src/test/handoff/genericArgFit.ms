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

test "an int64 argument after an int32 binding is rejected" {
	const src = "function pick<T>(a: T, b: T): T { return a; }\nconst w: int64 = 5;\nconst c = pick(1, w);";
	assert hasError(src, "Argument type mismatch in 'pick' arg 1: got int64, expected int32");
}

test "the diagnostic names the widest candidate when it comes later" {
	const src = CLASSES + "function pair3<T>(a: T, b: T, c: T): T { return a; }\nconst c = pair3(dog, animal, \"s\");";
	assert hasError(src, "Argument type mismatch in 'pair3' arg 2: got string, expected Animal — 'T' was bound by argument 1");
}

test "sibling classes with no common binding are rejected" {
	const src = CLASSES + "class Cat extends Animal { lives: int32 = 9; }\nconst cat = new Cat();\nconst c = pair(dog, cat);";
	assert hasError(src, "Argument type mismatch in 'pair' arg 1: got Cat, expected Dog");
}

test "an explicit type arg the arguments contradict is still rejected" {
	assert hasError(CLASSES + "const c = pair<Dog>(dog, animal);", "Argument type mismatch in 'pair' arg 1: got Animal, expected Dog");
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

test "a base-class argument widens the binding instead of failing" {
	assert strictErrorCount(CLASSES + "const c = pair(dog, animal);") == 0;
}

test "a float64 argument widens an int32 binding" {
	const src = "function pick<T>(a: T, b: T): T { return a; }\nconst c = pick(1, 2.5);";
	assert strictErrorCount(src) == 0;
}

test "the common base is found regardless of argument order" {
	const src = CLASSES + "class Cat extends Animal { lives: int32 = 9; }\nconst cat = new Cat();\nfunction pair3<T>(a: T, b: T, c: T): T { return a; }\n";
	assert strictErrorCount(src + "const c = pair3(dog, cat, animal);") == 0;
	assert strictErrorCount(src + "const c = pair3(dog, animal, cat);") == 0;
	assert strictErrorCount(src + "const c = pair3(animal, dog, cat);") == 0;
}

test "a narrower interface widens a wider structural binding" {
	const src = "interface P { a: int32; }\ninterface PB { a: int32; b: int32; }\nfunction pair<T>(a: T, b: T): T { return a; }\nconst x: PB = { a: 1, b: 2 };\nconst y: P = { a: 3 };\nconst c = pair(x, y);";
	assert strictErrorCount(src) == 0;
}

test "an explicit base type arg is not second-guessed" {
	assert strictErrorCount(CLASSES + "const c = pair<Animal>(dog, animal);") == 0;
}

test "a template widens to the base class too" {
	const src = "class Animal { name: string = \"\"; }\nclass Dog extends Animal { breed: string = \"\"; }\ntemplate tpair<T>(a: T, b: T): T { return a; }\nconst dog = new Dog();\nconst animal = new Animal();\nconst c = tpair(dog, animal);";
	assert strictErrorCount(src) == 0;
}

test "a lambda typed from the formal does not report a conflict" {
	const src = "function mapAll<T, U>(xs: T[], f: (x: T) => U): U[] {\n\tconst out: U[] = [];\n\tfor (const x of xs) out.push(f(x));\n\treturn out;\n}\nconst a: int32[] = [1, 2];\nconst r = mapAll(a, (x: int32): string => \"v\");";
	assert strictErrorCount(src) == 0;
}

test "a template with matching arguments expands cleanly" {
	assert strictErrorCount(TPL_ID2 + "const c = id2(\"s\", \"t\");") == 0;
}

// ===== Explicit type arguments: arity is checked before binding =====

const TPL_CLASSES = "class Animal { name: string = \"\"; }\nclass Dog extends Animal { breed: string = \"\"; }\ntemplate tp<T>(a: T, b: T): T { return a; }\nconst dog = new Dog();\nconst animal = new Animal();\n";

test "too few explicit type arguments on a function are rejected" {
	assert hasError("function f2<A, B>(a: A, b: B): A { return a; }\nconst r = f2<string>(\"s\", 1);", "Wrong number of type arguments to 'f2': expected 2, got 1");
}

test "too many explicit type arguments on a function are rejected" {
	assert hasError("function f1<T>(a: T): T { return a; }\nconst r = f1<string, int32>(\"s\");", "Wrong number of type arguments to 'f1': expected 1, got 2");
}

test "explicit type arguments on a non-generic function are rejected" {
	assert hasError("function g(a: string): string { return a; }\nconst r = g<string>(\"s\");", "Wrong number of type arguments to 'g': expected 0, got 1");
}

test "a static method checks explicit type argument arity" {
	assert hasError("class K { static m<A, B>(a: A, b: B): A { return a; } }\nconst r = K.m<string>(\"s\", 1);", "Wrong number of type arguments to 'm': expected 2, got 1");
}

test "a template checks explicit type argument arity" {
	assert hasError("template t2<A, B>(a: A, b: B): A { return a; }\nconst r = t2<string>(\"s\", 1);", "Wrong number of type arguments to 't2': expected 2, got 1");
}

test "a class constructor checks explicit type argument arity" {
	assert hasError("class Box<T> { v: T; constructor(v: T) { this.v = v; } }\nconst b = new Box<string, int32>(\"s\");", "Wrong number of type arguments to 'Box': expected 1, got 2");
}

test "matching explicit type argument counts are accepted" {
	assert strictErrorCount("function f2<A, B>(a: A, b: B): A { return a; }\nconst r = f2<string, int32>(\"s\", 1);") == 0;
	assert strictErrorCount("class Pair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }\nconst p = new Pair<string, int32>(\"s\", 1);") == 0;
}

// ===== Explicit type arguments seed the template binding =====

test "a template argument contradicting an explicit type argument is rejected" {
	assert hasError(TPL_ID2 + "const c = id2<string>(3, 4);", "Argument type mismatch in 'id2' arg 0: got int32, expected string");
}

test "an explicit template binding is not widened by a later argument" {
	assert hasError(TPL_CLASSES + "const c = tp<Dog>(animal, dog);", "Argument type mismatch in 'tp' arg 0: got Animal, expected Dog");
}

test "a template finds the common base regardless of argument order" {
	const src = TPL_CLASSES + "class Cat extends Animal { lives: int32 = 9; }\nconst cat = new Cat();\ntemplate tp3<T>(a: T, b: T, c: T): T { return a; }\nconst c = tp3(dog, cat, animal);";
	assert strictErrorCount(src) == 0;
}

test "a template still rejects siblings with no covering candidate" {
	const src = TPL_CLASSES + "class Cat extends Animal { lives: int32 = 9; }\nconst cat = new Cat();\nconst c = tp(dog, cat);";
	assert hasError(src, "Argument type mismatch in 'tp' arg 1: got Cat, expected Dog");
}

test "an explicit template binding accepts subclass arguments in any order" {
	assert strictErrorCount(TPL_CLASSES + "const c = tp<Animal>(dog, animal);") == 0;
}

// ===== One diagnostic per explicit mismatch; rest params check their element =====

test "an explicit mismatch on a function is reported exactly once" {
	assert strictErrorCount("function pair<T>(a: T, b: T): T { return a; }\nconst c = pair<string>(\"s\", 3);") == 1;
}

test "a generic rest parameter accepts matching trailing arguments" {
	assert strictErrorCount("function all<T>(...xs: T[]): T { return xs[0]; }\nconst c = all<string>(\"a\", \"b\");") == 0;
	assert strictErrorCount("function f<T>(a: T, ...rest: T[]): T { return a; }\nconst c = f(\"a\", \"b\", \"c\");") == 0;
}

test "a generic rest parameter rejects a contradicting trailing argument by element type" {
	assert hasError("function f<T>(a: T, ...rest: T[]): T { return a; }\nconst c = f(\"a\", 3);", "Argument type mismatch in 'f' arg 1: got int32, expected string");
}

test "a type-parameter default is not read as another parameter" {
	const src = "function f<T, E = Map<string, int32>>(a: T): T { return a; }\n";
	assert strictErrorCount(src + "const r = f<int32, Map<string, int32>>(1);") == 0;
	assert strictErrorCount(src + "const r = f(\"s\");") == 0;
	assert hasError(src + "const r = f<int32>(1);", "Wrong number of type arguments to 'f': expected 2, got 1");
}
