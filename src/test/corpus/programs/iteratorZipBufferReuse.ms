// @stdout: 1,10|2,20|3,30
// @stdout: a,x|b,y
// @stdout: 1,10 2,20 3,30
// @stdout: ps,ru
// @stdout: 1498500 143 71142142071
// Iterator.zip may hand the consumer one buffer again once nothing else holds it. A pair the
// consumer keeps, in an outer array, a variable, a manual next() result or a field, must still
// read as it did when it was yielded, for int and string elements, so every lane prints the same.
function rows<T>(r: T[][]): string {
	const out: string[] = [];
	for (const row of r) out.push(row.join(","));
	return out.join("|");
}

struct Box {
	pair: string[];
}

const kept: int32[][] = [];
for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) kept.push(pair);
console.log(rows(kept));

const words: string[][] = [];
for (const pair of Iterator.zip<string>([["a", "b"].values(), ["x", "y"].values()])) words.push(pair);
console.log(rows(words));

const it = Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()]);
const r1 = it.next();
const r2 = it.next();
const r3 = it.next();
console.log(r1.value.join(",") + " " + r2.value.join(",") + " " + r3.value.join(","));

let held: int32[] = [];
for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) {
	if (pair[0] == 2) held = pair;
}
console.log(held.join(","));

const boxes: Box[] = [];
for (const pair of Iterator.zip<string>([["p", "q", "r"].values(), ["s", "t", "u"].values()])) {
	if (pair[0] != "q") boxes.push({ pair });
}
console.log(boxes.map((b) => b.pair.join("")).join(","));

let seen = "";
for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10].values()], { mode: "longest", padding: [0, -1] })) seen += pair.join(",") + ";";
console.log(seen);

const big: int32[] = [];
for (let i: int32 = 0; i < 1000; i++) big.push(i);
let sum: int64 = 0;
const every7: int32[][] = [];
let step = 0;
for (const pair of Iterator.zip<int32>([big.values(), big.values(), big.values()])) {
	sum += (pair[0] + pair[1] + pair[2]) as int64;
	if (step % 7 == 0) every7.push(pair);
	step += 1;
}
let check: int64 = 0;
for (const p of every7) check += (p[0] * 1000000 + p[1] * 1000 + p[2]) as int64;
console.log(sum.toString() + " " + every7.length.toString() + " " + check.toString());
