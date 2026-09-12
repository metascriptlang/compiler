// Route 15e: Checker — a distinct over a function type is nominal, callable through its base, and widens one way

import { strictErrorCount, hasError } from "./helpers";

const THUNK = "type Thunk<T> = distinct (() => T);\nconst t = (() => 7) as Thunk<number>;\n";
const TH = "type Th = distinct (() => number);\nconst t = (() => 7) as Th;\n";
const NEEDS = "function needsStr(s: string): string { return s; }\nfunction needsNum(n: number): number { return n; }\n";

// ===== Nominal =====

test "a generic distinct over a function type parses and casts" {
	assert strictErrorCount(THUNK) == 0;
}

test "the instance stays nominal against a callable slot of another shape" {
	assert hasError(THUNK + "const s: () => string = t;", "Type 'Thunk<number>' is not assignable to type 'function'");
}

test "sibling generic distincts stay apart" {
	assert hasError(THUNK + "type Other<T> = distinct (() => T);\nconst o: Other<number> = t;", "is not assignable to type 'Other<number>'");
}

// ===== Callable through the base =====

test "calling the instance yields the substituted return type" {
	assert strictErrorCount(THUNK + NEEDS + "const n: number = t();\nneedsNum(t());") == 0;
}

test "the call result is typed, not inferred" {
	assert hasError(THUNK + NEEDS + "needsStr(t());", "got number, expected string");
}

test "arity is checked through the base" {
	assert hasError(THUNK + "const n: number = t(1);", "Too many arguments");
}

test "the non-generic twin is called the same way" {
	assert strictErrorCount(TH + NEEDS + "needsNum(t());") == 0;
	assert hasError(TH + NEEDS + "needsStr(t());", "got number, expected string");
}

test "a member callee of distinct type is typed too" {
	const src = THUNK + NEEDS + "interface Box { f: Thunk<number>; }\nconst b: Box = { f: t };\nneedsStr(b.f());";
	assert hasError(src, "got number, expected string");
}

// ===== Widens one way =====

test "the instance widens to its base function type" {
	assert strictErrorCount(THUNK + "const f: () => number = t;") == 0;
}

test "the non-generic twin widens too" {
	assert strictErrorCount(TH + "const f: () => number = t;") == 0;
}

test "the base does not narrow to the distinct" {
	assert hasError(THUNK + "const t2: Thunk<number> = () => 1;", "is not assignable to type 'Thunk<number>'");
}

// ===== `as` types the operand against the distinct's function body =====

test "an arrow cast to a distinct over a function type is contextually typed by the body" {
	const src = "type Fn1<T> = distinct ((x: T) => T);\nconst id = ((x) => x) as Fn1<number>;\nconst y: number = id(3);";
	assert strictErrorCount(src) == 0;
}
