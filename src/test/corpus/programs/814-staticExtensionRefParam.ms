// @xfail(raiser): output differs from c: static ref 7 7 9 9 6 0
// @stdout: static ref 7 7 9 9 6 3
// note: a `ref` or `out` parameter of a `this typeof T` static extension, second or third after the receiver. The caller has to see every write; the modifier used to land on the parameter after it, so `bump(c)` changed a copy.

struct Ctx { n: int32; }
struct R { k: int32; }

function bump(ref c: Ctx): void {
	c.n = c.n + 1;
}

function seven(): int32 {
	return 7;
}

function create(this typeof R, ref c: Ctx, k: int32): R {
	bump(c);
	return { k: k };
}

function make(this typeof R, k: int32, name: string, ref c: Ctx): R {
	c.n = c.n + k;
	return { k: k + name.length };
}

function split(this typeof R, out half: int32, k: int32): R {
	half = k / 2;
	return { k: k };
}

let c: Ctx = { n: 0 };
let half: int32 = 0;
const a = R.create(c, 7);
const b = R.create(c, seven());
const m = R.make(seven(), "ab", c);
const s = R.split(half, 6);
console.log(`static ref ${a.k} ${b.k} ${c.n} ${m.k} ${s.k} ${half}`);
