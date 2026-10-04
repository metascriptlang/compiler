// @stdout: span=2 box=9 count=7 chain=18 own=18 recurse=500500 arrays=2,4,3,3
// note: a call to an overloaded function is lowered against the overload it resolves to, whatever the declaration order: a struct argument next to a `Span` overload, an integer next to a `Span<Meta>` overload, a call from the first overload to the second, a self tail call in the second overload, and fixed, `Vec` and `T[]` arguments reaching a `Span<int32>` overload as they reach a lone `Span<int32>` parameter. Same output on every backend.

struct Box { value: int32; }
struct Crate { weight: int32; }
struct Meta { a: int32; }

function pick(values: Readonly<Span<int32>>): int32 { return values.length as int32; }
function pick(box: Box): int32 { return box.value; }

function count(metas: Span<Meta>): uint64 { return metas.length as uint64; }
function count(one: uint64): uint64 { return one; }

function weigh(box: Box): int32 {
	const crate: Crate = { weight: box.value * 2 };
	return weigh(crate);
}
function weigh(crate: Crate): int32 { return crate.weight; }

function total(n: int32, acc: int32): int32 { return acc + n; }
function total(n: int64, acc: int64): int64 {
	if (n == 0) return acc;
	return total(n - 1, acc + n);
}

function take(box: Box): int32 { return box.value; }
function take(values: Readonly<Span<int32>>): int32 { return values.length as int32; }
function lone(values: Readonly<Span<int32>>): int32 { return values.length as int32; }

function main(): void {
	const items: int32[2] = [4, 5];
	const box: Box = { value: 9 };
	const fixed: int32[2] = [4, 5];
	const dyn: int32[] = [1, 2, 3];
	let vec: Vec<int32> = [];
	vec.push(1);
	vec.push(2);
	vec.push(3);
	vec.push(4);
	const arrays = `${take(fixed)},${take(vec)},${lone(dyn)},${take(dyn)}`;
	const recurse = total(1000 as int64, 0 as int64);
	console.log(`span=${pick(items)} box=${pick(box)} count=${count(7)} chain=${weigh(box)}`
		+ ` own=${weigh({ weight: 18 } as Crate)} recurse=${recurse} arrays=${arrays}`);
}

main();
