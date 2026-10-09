// @stdout: call=4,0,0 calls=3
// @xfail(raiser): the Raiser VM evaluates a call in front of `?.` and `??` once per read (calls=11 here; `n() ?? 0` alone calls n twice), inbox card 2026-10-08-raiser-evaluates-nullish-operand-twice
// note: a call in front of `?.` runs once: its result is tested for null and the field is read from that same result, through every link of the chain and the `??` after it.

interface Inline { inner: { v: int32 } | null }

let calls = 0;

function make(v: int32): Inline | null {
	calls = calls + 1;
	return v > 0 ? { inner: { v: v } } : (v == 0 ? { inner: null } : null);
}

const call = `${make(4)?.inner?.v ?? 0},${make(0)?.inner?.v ?? 0},${make(-1)?.inner?.v ?? 0}`;
console.log(`call=${call} calls=${calls}`);
