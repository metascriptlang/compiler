// @stdout: const=9 let=9 param=9 err=bad arg=9/5 pass=bad,9 text=hi join=9 fwd=true,false
// note: a binding copied from a Result that a guard narrowed keeps the narrowed variant, as the reference TypeScript types a const from its initializer's flow type, so the copy reads .value / .error without testing the discriminant again. Covered through const, let, a narrowed parameter, the error arm, the copy handed to a Result formal, returned through (also via a typed const and the error arm), a second payload type, and a join after the guard.

struct Key {
	b: uint8;
}

function pick(flag: boolean): Result<Key, string> {
	if (!flag) { return Result.err("bad"); }
	return Result.ok({ b: 9 });
}

function word(flag: boolean): Result<string, int32> {
	if (!flag) { return Result.err(7); }
	return Result.ok("hi");
}

function viaParam(r: Result<Key, string>): int32 {
	if (r.ok) {
		const h = r;
		return h.value.b as int32;
	}
	return -1;
}

function width(r: Result<Key, string>): int32 {
	if (r.ok) { return r.value.b as int32; }
	return 0;
}

function pass(r: Result<Key, string>): Result<Key, string> {
	if (!r.ok) {
		const h = r;
		console.log(h.error);
		return r;
	}
	return r;
}

function forward(r: Result<string, int32>): Result<string, int32> {
	if (r.ok) {
		const h = r;
		const q: Result<string, int32> = h;
		return q;
	}
	const e = r;
	return e;
}

function text(r: Result<string, int32>): string {
	if (r.ok) {
		let h = r;
		return h.value;
	}
	return "none";
}

function join(r: Result<Key, string>): int32 {
	let n = 0;
	if (r.ok) {
		const h = r;
		n = h.value.b as int32;
	}
	const again = r;
	return again.ok ? n : -1;
}

const got = pick(true);
let c = 0;
let l = 0;
if (got.ok) {
	const h = got;
	c = h.value.b as int32;
	let g = got;
	l = g.value.b as int32;
}
const bad = pick(false);
let e = "";
if (!bad.ok) {
	const h = bad;
	e = h.error;
}
let a = 0;
if (got.ok) {
	const h = got;
	a = width(h);
}
const back = pass(bad);
const through = pass(got);
console.log(`const=${c} let=${l} param=${viaParam(got)} err=${e} arg=${a}/${width(got) - 4} pass=${back.ok ? "ok" : back.error},${through.ok ? through.value.b : -1} text=${text(word(true))} join=${join(got)} fwd=${forward(word(true)).ok},${forward(word(false)).ok}`);
