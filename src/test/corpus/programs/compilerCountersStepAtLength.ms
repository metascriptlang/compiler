// @stdout: forOf 10 skip 8 string 6 spread 5 rest 2 7 pairs 14
// note: the counters the compiler writes for a for-of over an array or a string, a spread and a rest pattern reach every element once, a `continue` included.

interface P { a: int32; b: int32 }

function main(): void {
	const xs: int32[] = [1, 2, 3, 4];
	let sum: int32 = 0;
	for (const x of xs) sum += x;
	let skip: int32 = 0;
	for (const x of xs) {
		if (x == 2) continue;
		skip += x;
	}
	let bytes: int32 = 0;
	for (const c of "héllo") bytes += 1;
	const spread = [...xs, 9 as int32];
	const [first, ...rest] = spread;
	let pairs: int32 = 0;
	const ps: P[] = [{ a: 1, b: 2 }, { a: 3, b: 4 }];
	for (const { a, b } of ps) pairs += a * b;
	console.log(`forOf ${sum} skip ${skip} string ${bytes} spread ${spread.length} rest ${first + 1} ${rest.length + 3} pairs ${pairs}`);
}

main();
