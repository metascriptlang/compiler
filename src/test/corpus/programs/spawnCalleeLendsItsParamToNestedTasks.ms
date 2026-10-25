// @stdout: total=47960
// @skip-js: the callees await spawns in sync functions, and JS has no blocking wait
// note: a task calls a function that lends its Readonly parameter to nested tasks: awaited in place, through Promise.all, and held until the return. The parameter is a view of the parent's cell, and the env that carries it to the nested tasks counts nothing on it, so only the parent's thread ever counts the cell.

class Node { v: int32; constructor(v: int32) { this.v = v; } }

function leaf(n: Readonly<Node>): int32 { return n.v; }

function inPlace(n: Readonly<Node>, d: int32): int32 {
	if (d == 0) return n.v;
	return await spawn((): int32 => inPlace(n, d - 1));
}

function grouped(n: Readonly<Node>): int32 {
	const both = await Promise.all([spawn((): int32 => leaf(n)), spawn((): int32 => leaf(n))]);
	return both[0] + both[1];
}

function held(n: Readonly<Node>): int32 {
	const a = spawn((): int32 => leaf(n));
	const b = spawn((): int32 => leaf(n));
	return await b + await a;
}

function round(i: int32): int32 {
	const node = new Node(i % 7);
	const t = spawn((): int32 => inPlace(node, 3) + grouped(node) + held(node));
	const u = spawn((): int32 => grouped(node) + inPlace(node, 2));
	return await t + await u;
}

let total: int32 = 0;
for (let i: int32 = 0; i < 2000; i++) total += round(i);
console.log(`total=${total}`);
