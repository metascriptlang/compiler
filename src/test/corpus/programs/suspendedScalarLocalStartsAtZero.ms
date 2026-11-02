// @stdout: async Green 5 A 9
// @stdout: gen 1
// @stdout: gen Red 7 B 3
// note: a local declared without a value and assigned after a suspension point is hoisted into the routine's state, and starts at its type's zero for an enum, char and distinct scalar as for a number; a bigint starts empty, as a reference does.

enum Color { Red, Green }
type Port = distinct int32;

async function viaAwait(): Promise<void> {
	let e: Color;
	let c: bigint;
	let ch: char;
	let p: Port;
	await Promise.resolve(0);
	e = Color.Green;
	c = 5n;
	ch = 65 as char;
	p = 9 as Port;
	console.log(`async ${e} ${c} ${String.fromCharCode(ch as int32)} ${p as int32}`);
}

function* viaYield(): Iterator<int32> {
	let e: Color;
	let c: bigint;
	let ch: char;
	let p: Port;
	yield 1;
	e = Color.Red;
	c = 7n;
	ch = 66 as char;
	p = 3 as Port;
	console.log(`gen ${e} ${c} ${String.fromCharCode(ch as int32)} ${p as int32}`);
}

await viaAwait();
for (const x of viaYield()) console.log(`gen ${x}`);
