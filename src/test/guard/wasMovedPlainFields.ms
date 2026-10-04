// liftdestructors.nim defaultOp: wasMoved resets plain fields too; JS runs no struct hooks, so no GUARD-JS lane.

struct R { id: int32; name: string; }
struct W { r: R; k: int32; }
struct Holder { r: R; tag: string; }

const log: string[] = [];

function onDestroy(this x: R): void { log.push(x.id.toString()); }
function onDestroy(this x: W): void { log.push("w" + x.k.toString()); }

function mk(n: int32): R { return { id: n, name: "n" + n.toString() }; }
function mkW(n: int32): W { return { r: mk(n), k: n }; }

function plain(): void {
	let a = mk(1);
	const b = move a;
}

function nested(): void {
	let w = mkW(2);
	const w2 = move w;
}

function arrayElement(): void {
	let arr: R[] = new Array(0);
	const x = mk(3);
	arr.push(x);
}

function callResultField(): void {
	const h: Holder = { r: mk(4), tag: "t" };
}

plain();
nested();
arrayElement();
callResultField();

function count(key: string): int32 {
	let n: int32 = 0;
	for (const e of log) {
		if (e == key) n += 1;
	}
	return n;
}

let ok = true;
for (const key of ["1", "3", "4", "w2"]) {
	if (count(key) != 1) {
		console.log("GUARD-RED " + key + " destroyed " + count(key).toString() + " times: " + log.join(","));
		ok = false;
	}
}
if (ok) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
