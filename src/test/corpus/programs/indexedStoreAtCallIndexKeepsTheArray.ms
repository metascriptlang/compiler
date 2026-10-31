// @stdout: 7 3 6 9 12

function idx(b: int32): int32 { return b; }

class Box { p: Vec<uint32> = new Array(4); }

function noLoop(n: int32): uint32 {
	let p: Vec<uint32> = new Array(n);
	p[idx(0)] = 7;
	return p[0];
}

function inLoop(n: int32): float32 {
	let p: Vec<float32> = new Array(n);
	for (let i = 0; i < n; i++) p[idx(i)] = 3.0;
	return p[1];
}

function compound(n: int32): uint32 {
	let p: Vec<uint32> = new Array(n);
	p[idx(2)] += 5;
	p[idx(2)]++;
	return p[2];
}

function field(): uint32 {
	const b = new Box();
	b.p[idx(3)] = 9;
	return b.p[3];
}

function nested(): uint32 {
	let rows: Vec<Vec<uint32>> = [new Array(2), new Array(2)];
	rows[idx(1)][idx(0)] = 12;
	return rows[1][0];
}

console.log(`${noLoop(4)} ${inLoop(4)} ${compound(4)} ${field()} ${nested()}`);
