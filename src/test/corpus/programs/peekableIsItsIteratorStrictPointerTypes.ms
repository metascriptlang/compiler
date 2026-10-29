// @stdout: 2,4,6
// @stdout: aa-bb-cc
// @stdout: 1 3

@passC("-Werror=incompatible-pointer-types");

function main(): void {
	const nums: number[] = [1, 2, 3];
	const p = nums.values().peekable();
	const doubled = p.map((x: number): number => x * 2).toArray();
	console.log(doubled.join(","));

	const words: string[] = ["a", "b", "c"];
	const q = words.values().peekable();
	console.log(q.map((w: string): string => w + w).toArray().join("-"));

	const r = nums.values().peekable();
	const first = r.peek();
	const rest = r.map((x: number): number => x).toArray();
	console.log(first, rest.length);
}
main();
