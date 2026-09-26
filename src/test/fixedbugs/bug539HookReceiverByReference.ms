// bug539 — a value struct's onCopy took its destination by value
//
// Symptom:    `function onCopy(this self: Res, src: Res): void` on `struct Res` passed the checker; the
//             lifted `ResCopy(Res* dest, Res src)` then passed the pointer to a by-value parameter and
//             clang refused the program.
//
// Root cause: nothing checked a lifecycle hook's signature; the reference refuses `=copy`/`=sink` that
//             are not `proc(x: var T; y: T)` and `=wasMoved`/`=trace` without `var T` at the declaration
//             (semstmts.nim:2316, bindTypeHook).
//
// Fix:        resolveFunction refuses onCopy, onMove, onMoved and onTrace whose receiver is a value type.

import { errorCount, hasError } from "../handoff/helpers";

test "bug539: onCopy on a value struct receiver is refused at the declaration" {
	assert hasError("struct Res539 { h: int32; }\nfunction onCopy(this self: Res539, src: Res539): void { console.log(src.h.toString()); }\n",
		"signature for 'onCopy' must take its receiver by reference");
}

test "bug539: onMoved on a value struct receiver is refused at the declaration" {
	assert hasError("struct Res539 { h: int32; }\nfunction onMoved(this self: Res539): void { console.log(self.h.toString()); }\n",
		"signature for 'onMoved' must take its receiver by reference");
}

test "bug539: a class receiver is a reference and keeps its onCopy" {
	assert errorCount("class Obj539 { h: int32 = 0; }\nfunction onCopy(this self: Obj539, src: Obj539): void { self.h = src.h; }\n") == 0;
}
