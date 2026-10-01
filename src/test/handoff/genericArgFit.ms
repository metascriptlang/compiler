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
	const src = "function pick<T>(a: T, b: T): T { return a; }\nconst v: int32 = 1;\nconst w: int64 = 5;\nconst c = pick(v, w);";
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

// ===== A constrained type parameter binds under its own name =====

test "an explicit type argument on a constrained parameter is still checked" {
	const src = CLASSES + "function g<T extends Animal>(a: T, b: T): T { return a; }\nconst c = g<Dog>(dog, animal);";
	assert hasError(src, "Argument type mismatch in 'g' arg 1: got Animal, expected Dog");
}

test "a constrained parameter accepts a covering explicit type argument" {
	const src = CLASSES + "function g<T extends Animal>(a: T, b: T): T { return a; }\nconst c = g<Animal>(dog, animal);";
	assert strictErrorCount(src) == 0;
}

test "a constrained template parameter checks its explicit binding" {
	const src = TPL_CLASSES + "template tg<T extends Animal>(a: T, b: T): T { return a; }\nconst c = tg<Dog>(dog, animal);";
	assert hasError(src, "Argument type mismatch in 'tg' arg 1: got Animal, expected Dog");
}

test "a constrained template parameter checks its inferred binding" {
	const src = TPL_CLASSES + "template tg<T extends Animal>(a: T, b: T): T { return a; }\nconst c = tg(dog, \"s\");";
	assert hasError(src, "Argument type mismatch in 'tg' arg 1: got string, expected Dog");
}

test "a numeric constraint keeps the explicit type argument over a wider literal" {
	const src = "function g<T extends number>(a: T, b: T): T { return a; }\n";
	assert hasError(src + "const c = g<int32>(1, 2.5);", "Argument type mismatch in 'g' arg 1: got float64, expected int32");
	assert strictErrorCount(src + "const c = g<float64>(1, 2.5);") == 0;
}

test "a constrained parameter after an unconstrained one keeps its explicit binding" {
	const src = CLASSES + "function g<U, T extends Animal>(u: U, a: T, b: T): T { return a; }\nconst c = g<string, Dog>(\"u\", dog, animal);";
	assert hasError(src, "Argument type mismatch in 'g' arg 2: got Animal, expected Dog");
}

// ===== A constraint limits what may bind its type parameter =====

const BOXED = CLASSES + "class Box { name: int32 = 7; }\nfunction g<T extends Animal>(a: T): T { return a; }\n";

test "an inferred binding outside its constraint is rejected at the argument" {
	assert hasError(BOXED + "const c = g(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'g'");
	assert hasError(BOXED + "const c = g(new Box());", "Type 'Box' does not satisfy constraint 'Animal' for type parameter 'T' in 'g'");
}

test "an explicit type argument outside its constraint is rejected" {
	assert hasError(BOXED + "const c = g<string>(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'g'");
}

test "a binding inside its constraint is accepted" {
	assert strictErrorCount(BOXED + "const c = g(dog);\nconst d = g<Dog>(dog);\nconst e = g(animal);") == 0;
}

test "a numeric constraint rejects a string and accepts every number" {
	const src = "function h<T extends number>(a: T): T { return a; }\n";
	assert hasError(src + "const c = h(\"s\");", "does not satisfy constraint");
	assert strictErrorCount(src + "const c = h(3);\nconst d = h(2.5);") == 0;
}

test "a constraint naming an earlier type parameter is checked after both bind" {
	const src = "function k<T, U extends T[]>(a: T, b: U): T { return a; }\n";
	assert hasError(src + "const c = k(1, [\"s\"]);", "does not satisfy constraint");
	assert strictErrorCount(src + "const c = k(1, [2]);") == 0;
}

test "a constrained template parameter rejects a binding outside its constraint" {
	const src = TPL_CLASSES + "template tg<T extends Animal>(a: T): T { return a; }\n";
	assert hasError(src + "const c = tg(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'tg'");
	assert hasError(src + "const c = tg<string>(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'tg'");
	assert strictErrorCount(src + "const c = tg(dog);") == 0;
}

test "a constraint with its own type arguments is read whole" {
	const arr = "function f<T extends Array<int32>>(a: T): T { return a; }\n";
	assert hasError(arr + "const c = f([\"s\"]);", "does not satisfy constraint");
	assert strictErrorCount(arr + "const c = f([1]);") == 0;
	const map = "function m<T extends Map<string, int32>, U>(a: T, b: U): U { return b; }\n";
	assert hasError(map + "const c = m(\"s\", 1);", "Type 'string' does not satisfy constraint");
	assert strictErrorCount(map + "const c = m(new Map<string, int32>(), 1);") == 0;
}

test "a union constraint is read whole" {
	const src = "function u<T extends string | int32>(a: T): T { return a; }\n";
	assert hasError(src + "const c = u(true);", "does not satisfy constraint");
	assert strictErrorCount(src + "const c = u(\"s\");\nconst d = u(3);") == 0;
}

test "an extension's own constrained parameter is checked when its receiver binds it" {
	const src = CLASSES + "function tagged<T extends Animal>(this xs: T[]): int32 { return xs.length; }\n";
	assert hasError(src + "const c = [\"s\"].tagged();", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'tagged'");
	assert strictErrorCount(src + "const d: Dog[] = [dog];\nconst c = d.tagged();") == 0;
}

test "a method's and a static method's own constraint is checked" {
	const src = CLASSES + "class H { n: int32 = 0; pick<T extends Animal>(a: T): T { return a; } static take<T extends Animal>(a: T): T { return a; } }\n";
	assert hasError(src + "const c = new H().pick(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'pick'");
	assert hasError(src + "const c = H.take(\"s\");", "Type 'string' does not satisfy constraint 'Animal' for type parameter 'T' in 'take'");
	assert strictErrorCount(src + "const c = new H().pick(dog);\nconst d = H.take(animal);") == 0;
}

// ===== One rule settles every candidate of a type parameter =====

const PAIR = "interface Pair<A, B> { first: A; second: B; }\nfunction same<T>(p: Pair<T, T>): T { return p.first; }\n";

test "numeric candidates inside one argument are refused alike in either order" {
	const a = PAIR + "const p: Pair<int32, float64> = { first: 1, second: 2.5 };\nconst c = same(p);";
	const b = PAIR + "const p: Pair<float64, int32> = { first: 2.5, second: 1 };\nconst c = same(p);";
	assert hasError(a, "Argument type mismatch in 'same' arg 0: got Pair");
	assert hasError(b, "Argument type mismatch in 'same' arg 0: got Pair");
	assert !hasError(a, "is bound to both");
	assert strictErrorCount(a) == 1;
	assert strictErrorCount(b) == 1;
}

test "class candidates inside one argument are refused alike in either order" {
	const a = CLASSES + PAIR + "const p: Pair<Dog, Animal> = { first: dog, second: animal };\nconst c = same(p);";
	const b = CLASSES + PAIR + "const p: Pair<Animal, Dog> = { first: animal, second: dog };\nconst c = same(p);";
	assert hasError(a, "Argument type mismatch in 'same' arg 0: got Pair");
	assert hasError(b, "Argument type mismatch in 'same' arg 0: got Pair");
}

test "sibling candidates inside one argument are rejected" {
	const src = CLASSES + "class Cat extends Animal { lives: int32 = 9; }\n" + PAIR + "const cat = new Cat();\nconst p: Pair<Dog, Cat> = { first: dog, second: cat };\nconst c = same(p);";
	assert hasError(src, "Argument type mismatch in 'same' arg 0");
}

test "candidates across arguments settle on the wider one in either order" {
	assert strictErrorCount("function pick<T>(a: T, b: T): T { return a; }\nconst c = pick(1, 2.5);\nconst d = pick(2.5, 1);") == 0;
	assert strictErrorCount(CLASSES + "const c = pair(animal, dog);\nconst d = pair(dog, animal);") == 0;
}
