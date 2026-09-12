// Route 15i: Checker — a generic call in a nullable slot binds from the payload; a distinct instance is invariant

import { strictErrorCount, hasError } from "./helpers";

const ACC = "type Acc<T> = distinct (() => T);\nfunction accessor<T>(f: () => T): Acc<T> { return f as Acc<T>; }\n"
	+ "interface P { a?: Acc<number> | null; s?: Acc<string> | null; }\ninterface Solo { a: Acc<number>; }\n";

test "a generic call in a nullable slot binds its parameter from the slot's payload" {
	assert strictErrorCount(ACC + "const p: P = { a: accessor(() => 122), s: null };\nconst q: P = { a: null, s: accessor(() => \"z\") };\nfunction r(p: P): number { const { a = accessor(() => 500) } = p; return a + 0; }") == 0;
}

test "a distinct instance is invariant in its type argument" {
	assert hasError(ACC + "const i = accessor(() => 1);\nconst q: Solo = { a: i };", "not assignable");
	assert hasError(ACC + "const i = accessor(() => 1);\nconst p: P = { a: i, s: null };", "not assignable");
	assert strictErrorCount(ACC + "const ok: Solo = { a: accessor<number>(() => 1) };\nconst ok2: Solo = { a: accessor(() => 1) };\nconst ok3: P = { a: accessor<number>(() => 1), s: null };") == 0;
}
