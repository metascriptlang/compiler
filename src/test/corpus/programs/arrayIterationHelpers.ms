// every and reduce read a length snapshot; values, keys and entries re-read the length at each step.
// @stdout: ok
let t = "";
const xs: int32[] = [2, 4, 5, 6];
let calls = "";
const r1 = xs.every((x: int32, i: number): boolean => {
	calls += `e${i},`;
	return x % 2 == 0;
});
t += `${r1} ${calls}|`;
const none: int32[] = [];
t += `${none.every((x: int32, i: number): boolean => false)}|`;
const a: int32[] = [1, 2];
const r2 = a.every((x: int32, i: number): boolean => {
	a.push(x + 10);
	return true;
});
t += `${r2} ${a.length}|`;
let first: number = -1;
const r3 = [1, 2, 3, 4].reduce((acc: int32, x: int32, i: number): int32 => {
	if (first < 0) first = i;
	return acc + x;
});
t += `${r3}@${first}|`;
first = -1;
const r4 = [1, 2, 3].reduce((acc: string, x: int32, i: number): string => {
	if (first < 0) first = i;
	return acc + x;
}, "n");
t += `${r4}@${first}|`;
const words: string[] = ["a", "bb", "ccc"];
t += `${words.reduce((acc: int32, w: string, i: number): int32 => acc + w.length, 0)}|`;
try {
	none.reduce((acc: int32, x: int32, i: number): int32 => acc + x);
} catch (e) {
	t += `${e.message}|`;
}
const b: int32[] = [1, 2];
for (const v of b.values()) {
	t += `v${v},`;
	if (v < 3) b.push(v + 2);
}
t += "|";
const c: int32[] = [5];
for (const k of c.keys()) {
	t += `k${k},`;
	if (c.length < 3) c.push(0);
}
t += "|";
const letters: string[] = ["x", "y", "z"];
for (const [i, v] of letters.entries()) {
	if (i == 2) break;
	t += `${i}${v},`;
}
const expected = "false e0,e1,e2,|true|true 4|10@1|n123@0|6|Reduce of empty array with no initial value|v1,v2,v3,v4,|k0,k1,k2,|0x,1y,";
if (t != expected) throw new Error(`array iteration trace differs:\n${t}\n${expected}`);
console.log("ok");
