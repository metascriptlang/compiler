// bug548 — a `T | null` value was accepted at a non-null slot and dereferenced later
//
// Symptom:    `const m = mk(false); const y: Box = m;` compiled; C then panicked with "member access
//             within null pointer" at `y.v` and JS threw a TypeError. `g(m)` with `g(b: Box)` was
//             already refused, so the argument and the declaration disagreed.
//
// Root cause: slotRefuses exempted a source whose only refused part was null (`null`, `T | null`,
//             `Maybe<T>`), so every declaration, assignment, field and return slot let it through.
//
// Fix:        the exemption is gone (the person's decision Q4): a nullable value fills a non-null
//             slot only after narrowing, at every slot, as the argument relation already did.

import { errorCount, hasError } from "../handoff/helpers";

const BOX548 = "class Box548 {\n\tv: int32;\n\tconstructor(v: int32) { this.v = v; }\n}\nfunction mk548(flag: boolean): Box548 | null {\n\tif (flag) return new Box548(1);\n\treturn null;\n}\n";

test "bug548: a nullable class value is refused at a declaration, an assignment and a return" {
	assert hasError(BOX548 + "function a(): int32 {\n\tconst m = mk548(false);\n\tconst y: Box548 = m;\n\treturn y.v;\n}\n", "Type 'Box548 | null' is not assignable to type 'Box548'");
	assert hasError(BOX548 + "function b(): void {\n\tlet y: Box548 = new Box548(2);\n\ty = mk548(true);\n}\n", "is not assignable to type 'Box548'");
	assert hasError(BOX548 + "function c(): Box548 {\n\treturn mk548(true);\n}\n", "is not assignable to type 'Box548'");
}

test "bug548: a nullable value type and a null literal are refused at a non-null slot" {
	assert hasError("function pick(f: boolean): int32 | null { return f ? 3 : null; }\nfunction d(): int32 {\n\tconst n: int32 = pick(true);\n\treturn n;\n}\n", "is not assignable to type 'int32'");
	assert hasError("class Box548b { v: int32 = 1; }\nfunction e(): void {\n\tlet b: Box548b = new Box548b();\n\tb = null;\n}\n", "Type 'null' is not assignable to type 'Box548b'");
}

test "bug548: a narrowed nullable value fills the slot" {
	assert errorCount(BOX548 + "function f(): int32 {\n\tconst m = mk548(true);\n\tif (m != null) {\n\t\tconst y: Box548 = m;\n\t\treturn y.v;\n\t}\n\treturn 0;\n}\n") == 0;
}
