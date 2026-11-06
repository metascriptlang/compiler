// keys() and entries() yield their index as a number: read back as an index, cast to a narrower integer, or used as
// a number in arithmetic, it keeps its TS value.
//
// @stdout: 45150 300 150 44850 22425 127.5 75 149.5

function main(): void {
	const xs: int32[] = [];
	for (let i: int32 = 0; i < 300; i++) xs.push(i + 1);
	let byKey: int32 = 0;
	let count: int32 = 0;
	for (const k of xs.keys()) {
		byKey += xs[k];
		count += 1;
	}
	let odd: int32 = 0;
	let keySum: int32 = 0;
	let half: number = 0;
	for (const [k, x] of xs.entries()) {
		odd += (k as int32) & 1;
		keySum += k as int32;
		if (k == 255) half = k / 2;
	}
	let small: int32 = 0;
	for (const k of xs.keys()) small += (k as int16) & 1;
	let last: number = 0;
	for (const k of xs.keys()) last = k / 2;
	console.log(`${byKey} ${count} ${odd} ${keySum} ${keySum / 2} ${half} ${small / 2} ${last}`);
}

main();
