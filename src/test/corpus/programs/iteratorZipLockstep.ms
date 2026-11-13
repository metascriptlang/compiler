// @stdout: dot 32
// @stdout: indexed 11,22,33
// @stdout: grown 1:10,2:20,3:30,4:40
// @stdout: shrunk 1:10,2:20
// @stdout: jumps 2,4,2,4|2
// @stdout: three 0:1:1,1:2:2,2:3:3
// @stdout: entries 0a0x,1b1y
// @stdout: order a b 1:10
// @stdout: rebound 1:10,2:20,3:30
// @stdout: raised 2
// @stdout: effects t1 t2 t3 33
// @stdout: escaping 1,10|2,20
// Iterator.zip over array iterators keeps the spec's lockstep: it stops at the shortest source, reads each
// length live, evaluates its sources' receivers once in order, and runs a source's value before it finds the next source done.
function dot(a: int32[], b: int32[]): int32 {
	let s: int32 = 0;
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) s += x * y;
	return s;
}

function indexed(a: int32[], b: int32[]): string {
	const out: string[] = [];
	for (const pair of Iterator.zip([a.values(), b.values()])) out.push(String(pair[0] + pair[1]));
	return out.join(",");
}

function grown(): string {
	const a: int32[] = [1, 2, 3, 4];
	const b: int32[] = [10, 20];
	const out: string[] = [];
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) {
		if (b.length < 4) b.push(y + 20);
		out.push(`${x}:${y}`);
	}
	return out.join(",");
}

function shrunk(): string {
	const a: int32[] = [1, 2, 3, 4];
	const b: int32[] = [10, 20, 30, 40];
	const out: string[] = [];
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) {
		b.pop();
		out.push(`${x}:${y}`);
	}
	return out.join(",");
}

function jumps(): string {
	const a: int32[] = [1, 2, 3, 4, 5, 6];
	const kept: string[] = [];
	let rounds = 0;
	for (let r = 0; r < 3; r++) {
		rounds += 1;
		let stop = false;
		for (const [x, y] of Iterator.zip([a.values(), a.values()])) {
			if (x % 2 == 1) continue;
			kept.push(String(x + y - x));
			if (y == 4) {
				stop = r == 1;
				break;
			}
		}
		if (stop) break;
	}
	return kept.join(",") + "|" + String(rounds);
}

function three(): string {
	const a: number[] = [1, 2, 3];
	const out: string[] = [];
	for (const [k, x, y] of Iterator.zip([a.keys(), a.values(), a.values()])) out.push(`${k}:${x}:${y}`);
	return out.join(",");
}

function entries(): string {
	const a: string[] = ["a", "b", "c"];
	const b: string[] = ["x", "y"];
	const out: string[] = [];
	for (const [[i, x], [j, y]] of Iterator.zip([a.entries(), b.entries()])) out.push(`${i}${x}${j}${y}`);
	return out.join(",");
}

const order: string[] = [];
function noted(tag: string, a: int32[]): int32[] {
	order.push(tag);
	return a;
}

function ordered(): string {
	let first = "";
	for (const [x, y] of Iterator.zip([noted("a", [1, 2]).values(), noted("b", [10]).values()])) {
		if (first == "") first = order.join(" ");
		order.push(`${x}:${y}`);
	}
	return first + " " + order[order.length - 1];
}

function rebound(): string {
	let a: int32[] = [1, 2, 3];
	const b: int32[] = [10, 20, 30];
	const out: string[] = [];
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) {
		a = [];
		out.push(`${x}:${y}`);
	}
	return out.join(",") + (a.length == 0 ? "" : "!");
}

function raised(): string {
	const a: int32[] = [1, 2, 3];
	let seen = 0;
	try {
		for (const [x, y] of Iterator.zip([a.values(), a.values()])) {
			if (x == 3) throw new Error("stop");
			seen += y - x + 1;
		}
	} catch (e) {
		return String(seen);
	}
	return "none";
}

const tags: string[] = [];
function tagged(x: int32): int32 {
	tags.push(`t${x}`);
	return x;
}

function* taggedValues(a: int32[]): Iterator<int32> {
	for (let i: int64 = 0; i < (a.length as int64); i += 1) yield tagged(a[i]);
}

function effects(): string {
	const a: int32[] = [1, 2, 3];
	const b: int32[] = [10, 20];
	let s: int32 = 0;
	for (const [x, y] of Iterator.zip([taggedValues(a), b.values()])) s += x + y;
	return tags.join(" ") + " " + String(s);
}

function escaping(): string {
	const kept: int32[][] = [];
	for (const pair of Iterator.zip([[1, 2].values(), [10, 20, 30].values()])) kept.push(pair);
	return kept.map((p) => p.join(",")).join("|");
}

console.log("dot " + String(dot([1, 2, 3], [4, 5, 6, 7])));
console.log("indexed " + indexed([1, 2, 3], [10, 20, 30, 40]));
console.log("grown " + grown());
console.log("shrunk " + shrunk());
console.log("jumps " + jumps());
console.log("three " + three());
console.log("entries " + entries());
console.log("order " + ordered());
console.log("rebound " + rebound());
console.log("raised " + raised());
console.log("effects " + effects());
console.log("escaping " + escaping());
