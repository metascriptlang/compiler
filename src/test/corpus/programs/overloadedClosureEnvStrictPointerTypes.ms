// @stdout: 3 21 5
// @stdout: tally 1 1

@passC("-Werror=incompatible-pointer-types");

class Tri { tag: int32 = 2; }
class Solo { tag: int32 = 20; }
class Pair<T> { tag: T; constructor(tag: T) { this.tag = tag; } }

function work(n: int32): int32 { return n + 1; }
function apply(f: () => int32): int32 { return f(); }

function bump(x: Tri): int32 {
	const c = () => work(x.tag);
	return c();
}

function bump(x: Solo): int32 {
	return apply(() => work(x.tag));
}

function bump(x: Pair<int32>): int32 {
	const c = () => x.tag;
	return c() + 1;
}

function tally(this x: Tri): int32 {
	const c = () => work(x.tag);
	return c() - x.tag;
}

function tally(this x: Solo): int32 {
	return apply(() => work(x.tag)) - x.tag;
}

console.log(bump(new Tri()), bump(new Solo()), bump(new Pair<int32>(4)));
console.log("tally", new Tri().tally(), new Solo().tally());
