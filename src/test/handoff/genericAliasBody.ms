// Route 15e: Checker — a generic alias instance carries its substituted body whatever the body kind

import { strictErrorCount, hasError } from "./helpers";

const SETTER = "type Setter<T> = (v: T) => void;\n";
const BOX = "type Box<T> = T[];\n";
const PAIR = "type Pair<T> = [T, T];\n";

// ===== Function body =====

test "a generic alias over a function type accepts a matching arrow in a field" {
	assert strictErrorCount(SETTER + "interface Cell<T> { set: Setter<T>; }\nconst c: Cell<int32> = { set: (v: int32) => {} };") == 0;
}

test "a generic alias over a function type is callable with the substituted parameter" {
	assert strictErrorCount(SETTER + "const s: Setter<int32> = (v: int32) => {};\ns(1);") == 0;
	assert strictErrorCount(SETTER + "const s: Setter<int32> = (v: int32) => {};\ns(\"x\");") == 1;
}

test "a generic alias over a function type flows into the matching function slot" {
	assert strictErrorCount(SETTER + "function take(f: (v: int32) => void): void { f(1); }\nconst s: Setter<int32> = (v: int32) => {};\ntake(s);") == 0;
}

test "a generic alias over a function type rejects a different instantiation" {
	assert strictErrorCount(SETTER + "function take(f: Setter<string>): void {}\nconst s: Setter<int32> = (v: int32) => {};\ntake(s);") == 1;
}

test "a generic alias over a function type returns from a generic function" {
	assert strictErrorCount(SETTER + "function mk<T>(): [() => T, Setter<T>] { let cur: T = 0 as T; return [() => cur, (v: T) => { cur = v; }]; }\nconst [g, s] = mk<int32>();\ns(2);\nconst n: int32 = g();") == 0;
}

// ===== Array and tuple bodies =====

test "a generic alias over an array type returns from a generic function" {
	assert strictErrorCount(BOX + "function mk<T>(x: T): Box<T> { return [x]; }\nconst xs: Box<int32> = mk<int32>(1);\nconst n: int32 = xs.length;") == 0;
}

test "a generic alias over a tuple type indexes to the substituted element" {
	assert strictErrorCount(PAIR + "function mk<T>(x: T): Pair<T> { return [x, x]; }\nconst p: Pair<int32> = mk<int32>(1);\nconst a: int32 = p[0];") == 0;
}

// ===== Distinct stays nominal =====

test "a generic distinct over a function type still refuses a bare arrow" {
	assert hasError("type Thunk<T> = distinct (() => T);\nconst t: Thunk<int32> = () => 1;", "is not assignable to type 'Thunk<int32>'");
}
