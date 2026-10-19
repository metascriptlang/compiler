// @stdout: 0 10 10|0 0|0 2|0|nil 3 0|0 20
// @exit: 0

enum Wrap { Clamp, Repeat, Mirror }

struct Sampler {
	nearest: boolean;
	wrap: Wrap;
}

struct Inner {
	x: int32;
	mode: Wrap;
}

struct Outer {
	k: int32;
	inner: Inner;
}

struct Deep {
	outer: Outer;
	tag: int32;
}

struct Opt {
	inner: Inner | null;
	n: int32;
	hook: (() => int32) | null;
}

struct Base {
	mode: Wrap;
	k: int32;
}

function pick(s: Sampler): int32 {
	return match (s.wrap) { Wrap.Clamp => 10, Wrap.Repeat => 20, Wrap.Mirror => 30 };
}

const s: Sampler = { nearest: true };
const o: Outer = { k: 1 };
const d: Deep = { tag: 2 };
const op: Opt = { n: 3 };
const base: Base = { mode: Wrap.Repeat, k: 5 };
const spread: Sampler = { ...{ nearest: false, wrap: Wrap.Repeat } };
const opt = `${op.inner == null ? "nil" : "set"} ${op.n} ${op.hook == null ? 0 : 1}`;
console.log(`${s.wrap as int32} ${pick(s)} ${pick({ nearest: true })}|${o.inner.x} ${o.inner.mode as int32}|${d.outer.inner.x} ${d.tag}|${d.outer.k}|${opt}|${(spread.wrap as int32) - 1 + base.k - 5} ${pick(spread)}`);
