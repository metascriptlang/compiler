// Symptom: `x[]` was a parse error for every operand, so no diagnostic said which operands a deref takes.
// Root cause: no explicit deref existed; Nim's semDeref accepts only ptr and ref and reports a type mismatch otherwise (semexprs.nim:1709-1723).
// Fix: the checker accepts a Ptr<T> other than Ptr<void> and a Ref<T> of a value type, and names the operand otherwise.
import { compileToCWithStd } from "../helpers";

function derefError222(body: string): string {
	const result = compileToCWithStd(`
struct S222 { n: int32; }
class C222 { n: int32 = 1; }
interface I222 { n: int32; }
type T222 = { n: int32 };
function main(): int32 {
	const s: S222 = { n: 1 };
	const c = new C222();
	const i: I222 = { n: 1 };
	const t: T222 = { n: 1 };
	const a: int32[] = [1];
	const vp = null as unknown as Ptr<void>;
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug222: a struct value is not a pointer" {
	const e = derefError222("const x = s[];");
	assert e.indexOf("this operand is S222, a value", 0) >= 0, e;
}

test "bug222: a class, an interface, an object type and T[] are already references" {
	assert derefError222("const x = c[];").indexOf("this operand is C222, which is already a reference", 0) >= 0;
	assert derefError222("const x = i[];").indexOf("this operand is I222, which is already a reference", 0) >= 0;
	assert derefError222("const x = t[];").indexOf("this operand is T222, which is already a reference", 0) >= 0;
	assert derefError222("const x = a[];").indexOf("this operand is int32[], which is already a reference", 0) >= 0;
}

test "bug222: Ptr<void> needs a cast first" {
	assert derefError222("const x = vp[];").indexOf("cannot dereference Ptr<void>", 0) >= 0;
}

test "bug222: a Ptr<T> held in a const is still written through" {
	assert derefError222("let arr: S222[1] = [{ n: 1 }]; const p = arr[0] as Ptr<S222>; p[].n = 4;") == "";
}
