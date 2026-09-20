// bug197 — a protocol method applied itself inside its own body
//
// Symptom:    `function asString(this b: Box): string { const t: string = b; return t; }`
//             built clean and overflowed the stack at run time (exit 139, no
//             output); `valueOf` reading its own receiver into a typed slot did
//             the same.
// Cause:      the extension is registered while collecting, before its body is
//             checked, so the implicit read inside the body found the method
//             being defined and synthesized a call to it.
// Reference:  an implicit conversion routine becomes available only after its
//             own body has been checked, so the same slot inside the body is an
//             ordinary type mismatch there.
import { compileToCWithStd } from "../helpers";

function errorOf(source: string): string {
	const c = compileToCWithStd(source);
	return c.ok ? "" : c.error;
}

test "bug197: a converter does not apply inside its own body" {
	const e = errorOf(`
interface Box { n: int32; }
converter boxToText(b: Box): string {
	const t: string = b;
	return t;
}
function main(): void {
	const b: Box = { n: 1 };
	const s: string = b;
	console.log(s);
}
main();
`);
	assert e.contains("'boxToText' does not apply inside its own body"), e;
}

test "bug197: valueOf does not apply inside its own body" {
	const e = errorOf(`
type Acc = distinct (() => int32);
function valueOf(this a: Acc): int32 {
	const n: int32 = a;
	return n;
}
function main(): void {
	const a = (() => 5) as Acc;
	const v: int32 = a;
	console.log(v);
}
main();
`);
	assert e.contains("'valueOf' does not apply inside its own body"), e;
}

test "bug197: another type's converter still applies inside the body" {
	const e = errorOf(`
interface Inner { n: int32; }
interface Outer { inner: Inner; }
converter innerToText(i: Inner): string { return "inner"; }
converter outerToText(o: Outer): string {
	const t: string = o.inner;
	return t;
}
function main(): void {
	const o: Outer = { inner: { n: 1 } };
	const s: string = o;
	console.log(s);
}
main();
`);
	assert e == "", e;
}
