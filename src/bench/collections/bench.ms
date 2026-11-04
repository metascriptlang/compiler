import { bench } from "../harness";

let sink: number = 0;

const N: int32 = 10000;
const WORDS = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta"];

function lcg(count: int32): number[] {
	const out: number[] = [];
	let seed: int32 = 1;
	for (let i = 0; i < count; i++) {
		seed = (seed * 75 + 74) % 65537;
		out.push(seed);
	}
	return out;
}

const nums = lcg(N);
const keys: string[] = [];
for (const n of nums) keys.push("key" + String(n));

let csv = "";
for (let i: int32 = 0; i < 1000; i++) csv += WORDS[i & 7] + ",";
csv += "end";

let hay = "";
while (hay.length < 16384) hay += "abcdefghijklmnopqrstuvwxyz0123456789 ";

const intMap = new Map<int32, int32>();
for (let i: int32 = 0; i < N; i++) intMap.set(i, i);

bench("string += 1k", 0, () => {
	let out = "";
	for (let i: int32 = 0; i < 1000; i++) out += WORDS[i & 7];
	sink += out.length;
});
bench("template literal 1k", 0, () => {
	for (let i: int32 = 0; i < 1000; i++) sink += `${WORDS[i & 7]}:${i}`.length;
});
bench("number toString 1k", 0, () => {
	for (let i: int32 = 0; i < 1000; i++) sink += String(i * 7919).length;
});
bench("split 1k fields", 0, () => { sink += csv.split(",").length; });
bench("join 10k strings", 0, () => { sink += keys.join(",").length; });
bench("indexOf 16 KB miss", 0, () => { sink += hay.indexOf("zz9"); });
bench("includes 16 KB miss", 0, () => { if (!hay.includes("zz9")) sink += 1; });
bench("replaceAll 16 KB", 0, () => {
	sink += hay.replaceAll("abc", "XY").length;
});

bench("array push 10k", 0, () => {
	const out: number[] = [];
	for (let i: int32 = 0; i < N; i++) out.push(i);
	sink += out.length;
});
bench("sort 10k numbers", 0, () => {
	const copy = nums.slice();
	copy.sort((a, b) => a - b);
	sink += copy[0];
});
bench("sort 10k strings", 0, () => {
	const copy = keys.slice();
	copy.sort();
	sink += copy[0].length;
});
bench("map/filter 10k", 0, () => {
	const doubled = nums.map((x) => x * 2);
	const picked = doubled.filter((x) => x % 3 == 0);
	sink += picked.length;
});
bench("array slice 10k", 0, () => { sink += nums.slice().length; });
bench("array spread 10k", 0, () => { sink += [...nums].length; });

bench("Map set/get int 10k", 0, () => {
	const m = new Map<int32, int32>();
	for (let i: int32 = 0; i < N; i++) m.set(i, i);
	for (let i: int32 = 0; i < N; i++) {
		const v = m.get(i);
		if (v !== null) sink += v;
	}
});
bench("Map set/get string 10k", 0, () => {
	const m = new Map<string, int32>();
	for (let i: int32 = 0; i < N; i++) m.set(keys[i], i);
	for (let i: int32 = 0; i < N; i++) {
		const v = m.get(keys[i]);
		if (v !== null) sink += v;
	}
});
bench("Map forEach 10k", 0, () => {
	intMap.forEach((v, k) => { sink += v + k; });
});
bench("Set add/has 10k", 0, () => {
	const s = new Set<int32>();
	for (let i: int32 = 0; i < N; i++) s.add(i * 3);
	for (let i: int32 = 0; i < N; i++) if (s.has(i)) sink += 1;
});

if (sink < 0) console.log("unreachable", sink);
