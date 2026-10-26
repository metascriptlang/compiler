// Parity program — an object literal meeting `R<T, E> | null`, a generic discriminated-union
// alias under `| null`, is built as the variant of the union before the null carrier wraps it.
// The carrier took the bare literal, so C stored a struct pointer in a union slot.
//
// @stdout: s n
// @stdout: 3 e:bad 1
// @stdout: t 7 s:x
// @exit: 0

type R<T, E> = { ok: true, value: T } | { ok: false, error: E };
interface Box { r: R<int32, string> | null }

function make(kind: int32): R<int32, string> | null {
	return kind == 0 ? null : kind == 1 ? { ok: true, value: 3 } : { ok: false, error: "bad" };
}
function show(r: R<int32, string> | null): string {
	if (r === null) return "n";
	return r.ok ? r.value.toString() : "e:" + r.error;
}
function flip(on: boolean): R<string, int32> | null {
	return on ? { ok: true, value: "x" } : null;
}

const a: R<int32, string> | null = { ok: true, value: 3 };
const b: R<int32, string> | null = null;
console.log(a === null ? "n" : "s", b === null ? "n" : "s");
console.log(show(make(1)), show(make(2)), make(0) === null ? 1 : 0);

const box: Box = { r: { ok: true, value: 7 } };
const f = flip(true);
console.log(box.r === null ? "n" : "t", show(box.r) == "7" ? 7 : 0, f !== null && f.ok ? "s:" + f.value : "n");
