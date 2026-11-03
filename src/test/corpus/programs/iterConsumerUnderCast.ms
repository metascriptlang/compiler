// @stdout: add 20 | decl 12 | assign 15 | ret 6 | len 5 | twice 10 0 | after 1

function* count(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) yield i;
}

function* doubled(it: Iterator<int32>): Iterator<int32> {
	for (const x of it) yield x * 2;
}

function total(it: Iterator<int32>): int32 {
	let t: int32 = 0;
	for (const x of it) t += x;
	return t;
}

function collect(it: Iterator<int32>): int32[] {
	const out: int32[] = [];
	for (const x of it) out.push(x);
	return out;
}

function viaReturn(): int64 {
	return total(count(4)) as int64;
}

let calls = 0;
function tick(): int32 {
	calls += 1;
	return calls;
}

let s: int64 = 0;
s += (total(doubled(count(5)))) as int64;
const a = total(doubled(count(4))) as int64;
let b: int32 = 0;
b = total(count(6)) as int32;
const n = (collect(doubled(count(5)))).length;
const it = count(5);
const first = total(it) as int64;
const second = total(it) as int64;
const after = total(count(tick() + 1)) as int64;
console.log(`add ${s} | decl ${a} | assign ${b} | ret ${viaReturn()} | len ${n} | twice ${first} ${second} | after ${after}`);
