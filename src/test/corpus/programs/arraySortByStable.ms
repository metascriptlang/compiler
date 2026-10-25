// @stdout: sort-by-stable ok
// arr.sort(cmp) is a stable O(n log n) merge sort over a struct holding a string, a class, and numbers.
// Every key repeats, so equal keys must keep input order; the comparator throwing mid-merge must leave the array whole.
struct Rec { key: number; seq: number; tag: string }
class Obj { key: number; seq: number; constructor(key: number, seq: number) { this.key = key; this.seq = seq; } }

let seed = 12345;
function next(): number {
	seed = (seed * 75 + 74) % 65537;
	return seed;
}

function checkRecs(n: number, keys: number): boolean {
	const xs: Rec[] = [];
	for (let i = 0; i < n; i = i + 1) xs.push({ key: next() % keys, seq: i, tag: `t${i}` });
	xs.sort((a: Rec, b: Rec): number => a.key - b.key);
	for (let i = 0; i < n; i = i + 1) {
		if (xs[i].tag != `t${xs[i].seq}`) return false;
		if (i > 0 && (xs[i - 1].key > xs[i].key || (xs[i - 1].key == xs[i].key && xs[i - 1].seq > xs[i].seq))) return false;
	}
	return true;
}

function checkObjs(n: number, keys: number): boolean {
	const xs: Obj[] = [];
	for (let i = 0; i < n; i = i + 1) xs.push(new Obj(next() % keys, i));
	xs.sort((a: Obj, b: Obj): number => a.key - b.key);
	for (let i = 1; i < n; i = i + 1) {
		if (xs[i - 1].key > xs[i].key || (xs[i - 1].key == xs[i].key && xs[i - 1].seq > xs[i].seq)) return false;
	}
	return xs.length == n;
}

function checkThrow(): boolean {
	const xs: Rec[] = [];
	for (let i = 0; i < 40; i = i + 1) xs.push({ key: next() % 7, seq: i, tag: `t${i}` });
	let calls = 0;
	let thrown = false;
	try {
		xs.sort((a: Rec, b: Rec): number => {
			calls = calls + 1;
			if (calls == 60) throw new Error("stop");
			return a.key - b.key;
		});
	} catch (e) {
		thrown = true;
	}
	if (!thrown || xs.length != 40) return false;
	for (let i = 0; i < 40; i = i + 1) if (xs[i].tag != `t${xs[i].seq}`) return false;
	return true;
}

let ok = true;
for (let n = 0; n < 12; n = n + 1) {
	if (!checkRecs(n, 3)) ok = false;
	if (!checkObjs(n, 3)) ok = false;
}
if (!checkRecs(1001, 10)) ok = false;
if (!checkObjs(100000, 1000)) ok = false;
if (!checkThrow()) ok = false;
console.log(ok ? "sort-by-stable ok" : "sort-by-stable FAIL");
