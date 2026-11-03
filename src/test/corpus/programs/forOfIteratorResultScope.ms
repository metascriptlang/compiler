// @stdout: break 12|a.next,a.next,a.return
// @stdout: continue 13|b.next,b.next,b.next,b.next
// @stdout: next throws 12|c.next,c.next,c.next
// @stdout: body throws 12|d.next,d.next,d.return
// @stdout: 1,10|2,20|3,30
// @stdout: a,x|b,y|c,z

function counter(name: string, n: int32, failAt: int32, log: string[]): Iterator<int32> {
	let k: int32 = 0;
	return {
		next: () => {
			log.push(`${name}.next`);
			if (k == failAt) throw new Error("boom");
			if (k >= n) return { value: 0, done: true };
			k += 1;
			return { value: k, done: false };
		},
		return: () => {
			log.push(`${name}.return`);
			return { value: 0, done: true };
		},
	};
}

function rows<T>(r: T[][]): string {
	const out: string[] = [];
	for (const row of r) out.push(row.join(","));
	return out.join("|");
}

const logA: string[] = [];
let seenA = "";
for (const x of counter("a", 5, -1, logA)) {
	seenA += x;
	if (x == 2) break;
}
console.log(`break ${seenA}|${logA.join(",")}`);

const logB: string[] = [];
let seenB = "";
for (const x of counter("b", 3, -1, logB)) {
	if (x == 2) continue;
	seenB += x;
}
console.log(`continue ${seenB}|${logB.join(",")}`);

const logC: string[] = [];
let seenC = "";
try {
	for (const x of counter("c", 5, 2, logC)) seenC += x;
} catch (e) {
	seenC += "";
}
console.log(`next throws ${seenC}|${logC.join(",")}`);

const logD: string[] = [];
let seenD = "";
try {
	for (const x of counter("d", 5, -1, logD)) {
		seenD += x;
		if (x == 2) throw new Error("body");
	}
} catch (e) {
	seenD += "";
}
console.log(`body throws ${seenD}|${logD.join(",")}`);

const ints: int32[][] = [];
for (const pair of Iterator.zip<int32>([[1, 2, 3].values(), [10, 20, 30].values()])) ints.push(pair);
console.log(rows(ints));

const words: string[][] = [];
for (const pair of Iterator.zip<string>([["a", "b", "c"].values(), ["x", "y", "z"].values()])) words.push(pair);
console.log(rows(words));
