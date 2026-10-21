// Checker — `keyof T`, `T[K]` and `t[key]` with a key of string literal type

import { strictErrorCount, hasError } from "./helpers";

const TODO = "interface Todo { title: string; done: boolean; }\nconst t: Todo = { title: \"a\", done: false };\n";
const PICK = "function pick<K extends keyof Todo>(x: Todo, key: K): Todo[K] { return x[key]; }\n";
const PUT = "function put<K extends keyof Todo>(x: Todo, key: K, v: Todo[K]): void { x[key] = v; }\n";

test "keyof an object type is the union of its property names" {
	assert strictErrorCount(TODO + "const k: keyof Todo = \"done\";") == 0;
	assert hasError(TODO + "const k: keyof Todo = \"owner\";", "Type '\"owner\"' is not assignable");
	assert hasError("const k: keyof int32 = \"a\";", "'keyof int32' has no keys");
	assert strictErrorCount("function f<T>(k: keyof T): void {}") == 0;
}

test "T[K] is the type of the property K names, a union for a union of keys" {
	assert strictErrorCount(TODO + "const s: Todo[\"title\"] = \"x\";\nconst b: Todo[\"done\"] = true;") == 0;
	assert hasError(TODO + "const s: Todo[\"title\"] = true;", "not assignable");
	assert strictErrorCount(TODO + "const u: Todo[\"title\" | \"done\"] = true;") == 0;
	assert hasError(TODO + "const o: Todo[\"owner\"] = 1;", "'\"owner\"' is not a key of 'Todo'");
}

test "a type parameter constrained to keys infers the literal, one instance per key" {
	assert strictErrorCount(TODO + PICK + "const s: string = pick(t, \"title\");\nconst b: boolean = pick(t, \"done\");") == 0;
	assert hasError(TODO + PICK + "const b: boolean = pick(t, \"title\");", "not assignable");
	assert hasError(TODO + PICK + "pick(t, \"owner\");", "Type '\"owner\"' does not satisfy constraint");
	assert hasError(TODO + PUT + "put(t, \"done\", \"yes\");", "expected boolean");
}

const TRAPS = "class Traps<T> { get<K extends keyof T>(x: T, key: K): T[K] { return x[key]; } }\nconst s = new Traps<Todo>();\n";

test "keyof a type parameter is bound per instance and checked at the call" {
	assert strictErrorCount(TODO + TRAPS + "const b: boolean = s.get(t, \"done\");") == 0;
	assert hasError(TODO + TRAPS + "const b: string = s.get(t, \"done\");", "not assignable");
	assert hasError(TODO + TRAPS + "s.get(t, \"owner\");", "Type '\"owner\"' does not satisfy constraint");
}

const AT = "function at<T, K extends keyof T>(x: T, key: K): T[K] { const got: T[K] = Reflect.get(x, key) as T[K]; return got; }\n";

test "T[K] in a generic body is an indexed access in every instance, an array read by a number key too" {
	assert strictErrorCount(TODO + AT + "const ts: Todo[] = [t];\nconst e: Todo = at(ts, 0);\nconst n: number = at(ts, \"length\");\nconst s: string = at(t, \"title\");") == 0;
	assert hasError(TODO + AT + "const ts: Todo[] = [t];\nconst e: string = at(ts, 0);", "not assignable");
	assert hasError("function f<T>(x: T): int32 { let k = 0; const a: T[k] = []; return 0; }\nf<int32>(1);", "array size 'k' must be a compile-time integer constant");
}

test "an element access with a literal key is the property it names" {
	assert strictErrorCount(TODO + "const s: string = t[\"title\"];\nt[\"done\"] = true;") == 0;
	assert hasError(TODO + "t[\"owner\"];", "'\"owner\"' is not a key of 'Todo'");
	assert hasError(TODO + "const k: string = \"title\";\nt[k];", "has no '[]' operator");
}

test "a literal key reads a property of an inferred object type, a non-identifier name too" {
	const o = "const o = { plain: \"p\", \"data-probe\": \"d\" };\n";
	assert strictErrorCount(o + "const a: string = o[\"plain\"];\nconst b: string = o[\"data-probe\"];") == 0;
	assert hasError(o + "o[\"data-prob\"];", "'\"data-prob\"' is not a key of");
}
