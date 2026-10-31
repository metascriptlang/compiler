// @stdout: 210000 210000 true
// @stdout: 233,20013,55357,56832,55296,120,56320
// @stdout: 8 true true 30000 40000
// @stdout: 200001 true
// @stdout: 200001 true
// @stdout: 200002 true
// @stdout: 200002 true
// @stdout: 60000 60000 true
import { echo, lengthOf, unitAt, swap, build, Pair } from "./stringsLongWasm";

function rep(chunk: string, times: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < times; i = i + 1) { parts.push(chunk); }
	return parts.join("");
}

const a = rep("\u00e9\u4e2d\u{1F600}\uD800x\uDC00", 30000);
const ea = echo(a);
console.log(`${a.length} ${lengthOf(a)} ${ea == a}`);
const tail: string[] = [];
for (let k = 0; k < 7; k = k + 1) { tail.push(`${unitAt(ea, 209993 + k)}`); }
console.log(tail.join(","));

const left = rep("\u4e2d", 40000);
const right = rep("\u{1F600}", 15000);
const p: Pair = { left: left, n: 7, right: right };
const r = swap(p);
console.log(`${r.n} ${r.left == right} ${r.right == left} ${r.left.length} ${r.right.length}`);

const base = rep("a", 200000);
const t1 = base + "\u00e9";
const t2 = base + "\uD83D";
const t3 = base + "\uD83D\uDE00";
const t4 = base + "\uDE00\uD83D";
console.log(`${lengthOf(t1)} ${echo(t1) == t1}`);
console.log(`${lengthOf(t2)} ${echo(t2) == t2}`);
console.log(`${lengthOf(t3)} ${echo(t3) == t3}`);
console.log(`${lengthOf(t4)} ${echo(t4) == t4}`);

const b = build(20000);
console.log(`${b.length} ${lengthOf(b)} ${echo(b) == b}`);
