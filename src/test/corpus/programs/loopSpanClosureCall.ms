// A loop that calls a const closure touching no array keeps its result when its arrays are read through local
// spans: a fill loop, a mapped toArray, and a closure that writes an element of a module array the loop reads.
//
// @stdout: 2,4,6|3,5,7|1,11,21|6

const shared: int32[] = [1, 1, 1];

function filled(): string {
	const a: int32[] = [1, 2, 3];
	const out: int32[] = [0, 0, 0];
	const g = (x: int32): int32 => x * 2;
	for (let i: int32 = 0; i < a.length; i++) out[i] = g(a[i]);
	return out.join(",");
}

function mapped(): string {
	const a: int32[] = [1, 2, 3];
	return a.values().map((x) => x * 2 + 1).toArray().join(",");
}

function sharedWrite(): string {
	const bump = (i: int32): int32 => { shared[i] = shared[i] + i * 10; return shared[i]; };
	const out: int32[] = [0, 0, 0];
	for (let i: int32 = 0; i < shared.length; i++) out[i] = bump(i);
	return out.join(",");
}

function summed(): string {
	const a: int32[] = [1, 2, 3];
	const id = (x: int32): int32 => x;
	let s: int32 = 0;
	for (const x of a) s += id(x);
	return String(s);
}

console.log([filled(), mapped(), sharedWrite(), summed()].join("|"));
