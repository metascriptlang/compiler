// @stdout: 495 337 0 249271
// @stdout: -4 510 1006
// @stdout: 9.125 40 14
// @stdout: w0é w9é w46éw47éw48é true
// Arrays of numbers, floats, booleans and strings through growth, store, remove, reverse, sort and truncation: the same output on C and on the Raiser VM.

function fill(n: number): number[] {
	const xs: number[] = [];
	for (let i = 0; i < n; i += 1) xs.push((i * 7919) % 1009);
	return xs;
}

function main(): void {
	const xs = fill(500);
	xs[3] = -4;
	xs.splice(10, 5);
	let lo = 0;
	let hi = xs.length - 1;
	while (lo < hi) {
		const t = xs[lo];
		xs[lo] = xs[hi];
		xs[hi] = t;
		lo += 1;
		hi -= 1;
	}
	let sum: number = 0;
	for (let i = 0; i < xs.length; i += 1) sum += xs[i];
	console.log(`${xs.length} ${xs[0]} ${xs[xs.length - 1]} ${sum}`);
	const sorted = xs.slice(0);
	sorted.sort((a, b) => a - b);
	console.log(`${sorted[0]} ${sorted[250]} ${sorted[sorted.length - 1]}`);
	xs.splice(20, xs.length - 20);
	console.log(`${xs.length} ${xs.join(",")}`);
	const fs: number[] = [];
	for (let i = 0; i < 40; i += 1) fs.push(i / 4 + 0.125);
	const flags: boolean[] = [];
	for (let i = 0; i < 40; i += 1) flags.push(i % 3 == 0);
	let on: number = 0;
	for (const f of flags) if (f) on += 1;
	console.log(`${fs[39]} ${fs.length} ${on}`);
	const words: string[] = [];
	for (let i = 0; i < 60; i += 1) words.push(`w${(i * 37) % 60}é`);
	words.sort();
	const grid: string[][] = [];
	for (let r = 0; r < 5; r += 1) grid.push(words.slice(r * 10, r * 10 + 3));
	console.log(`${words[0]} ${words[59]} ${grid[4].join("")} ${words.indexOf(grid[2][1]) >= 0}`);
}

main();
