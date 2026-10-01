// Symptom: a user operator with a `ref` parameter, written in operator form (`x /= 3`, `x + 3`, `-x`), threw on JS (`Cannot set properties of undefined`) while C printed the written value; a self tail call passing a `ref` parameter back copied it into a loop value, so C refused to compile it and JS wrote nowhere.
// Root cause: the JS pass that passes a location for a `ref` argument ran before operators became calls, so an operator call passed the bare value; tailCallLower carried a `ref` parameter in a value local.
// Fix: the JS location pass runs after every call is materialized, where the C pass already runs, as Nim marks address-taken arguments on every resolved call, operators included; a `ref` slot every self tail call refills with the parameter keeps the parameter, any other argument there keeps the routine recursive, as Nim maps a var formal straight to its argument.
// Runtime on every lane: corpus 677.
import { compileToC, compileToJS } from "../helpers";

function emitJs(src: string): string {
	const r = compileToJS(src);
	return r.ok ? r.value : "error: " + r.error;
}

function emitC(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : "error: " + r.error;
}

test "bug636: a compound operator with a ref parameter passes a location on JS" {
	const out = emitJs(`
function \`/=\`(ref a: int32, b: int32): void { a = 9; }
let x: int32 = 100;
x /= 3;
console.log(x);
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf(", 0], 3)", 0) >= 0, out;
}

test "bug636: a unary operator with a ref parameter passes a location on JS" {
	const out = emitJs(`
struct P { v: int32; }
function \`-\`(ref a: P): P { a = { v: 9 }; return { v: 1 }; }
let x: P = { v: 100 };
const y: P = -x;
console.log(x.v, y.v);
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf(", 0])", 0) >= 0, out;
}

test "bug636: a ref parameter passed back by a self tail call is not copied into the loop" {
	const out = emitC(`
function countDown(ref acc: int32, n: int32): void {
	if (n == 0) return;
	acc = acc + n;
	return countDown(acc, n - 1);
}
let total: int32 = 0;
countDown(total, 4);
console.log(total);
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("__tcl", 0) >= 0, out;
	assert out.indexOf("= (*acc)", 0) < 0, out;
}

test "bug636: a self tail call that moves a ref parameter to another location stays recursive" {
	const out = emitC(`
function alternate(ref a: int32, ref b: int32, n: int32): void {
	if (n == 0) return;
	a = a + n;
	return alternate(b, a, n - 1);
}
let p: int32 = 0;
let q: int32 = 0;
alternate(p, q, 4);
console.log(p, q);
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("__tcl", 0) < 0, out;
}
