// @stdout: trail a,gen-b,c,gen-d,gen-e,gen-f,gen-g,gen-h,6 | values 5 4 21 4 | v 31

const trail: string[] = [];
let v: int32 = 1;

function mark(name: string): int32 {
	trail.push(name);
	return 1;
}

function* gen(name: string, n: int32): Iterator<int32> {
	trail.push("gen-" + name);
	for (let i: int32 = 0; i < n; i++) yield i;
}

function collect(it: Iterator<int32>): int32[] {
	const out: int32[] = [];
	for (const x of it) out.push(x);
	return out;
}

function total(it: Iterator<int32>): int32 {
	let t: int32 = 0;
	for (const x of it) t += x;
	return t;
}

function totalBump(it: Iterator<int32>): int32 {
	let t: int32 = 0;
	for (const x of it) {
		t += x;
		v += 10;
	}
	return t;
}

function pair(a: int32, b: int32[]): int32 {
	return a + b.length;
}

function two(a: int32[], b: int32[]): int32 {
	return a.length * 10 + b.length;
}

function third(a: int32, b: int32, c: int32): int32 {
	return a + b + c;
}

const r1 = pair(mark("a"), collect(gen("b", 4)));
const flag = trail.length > 0;
const r2 = pair(flag ? mark("c") : 0, collect(gen("d", 3)));
const r3 = two(collect(gen("e", 2)), collect(gen("f", 1)));
const r4 = third(v, totalBump(gen("g", 3)), 0);
trail.push(String(total(gen("h", 4))));
console.log(`trail ${trail.join(",")} | values ${r1} ${r2} ${r3} ${r4} | v ${v}`);
