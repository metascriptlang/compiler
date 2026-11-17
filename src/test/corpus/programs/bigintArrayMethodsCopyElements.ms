// @stdout: xs 3 100000000000000000000,100000000000000000002,100000000000000000003
// @stdout: sliced 2 100000000000000000001,100000000000000000002
// @stdout: joined 2 100000000000000000000,100000000000000000001
// @stdout: spread 3 100000000000000000001,100000000000000000002,100000000000000000003
// @stdout: filled 3 100000000000000000000,100000000000000000000,100000000000000000000
// @stdout: mapped 3 100000000000000000001,100000000000000000003,100000000000000000004
// @stdout: filtered 5 100000000000000000001,100000000000000000002,100000000000000000003,100000000000000000001,100000000000000000002
// @stdout: reversed 6 100000000000000000002,100000000000000000001,100000000000000000003,100000000000000000002,100000000000000000001,100000000000000000000
// @stdout: true 2

function build(seed: bigint): bigint[] {
	const xs: bigint[] = [];
	for (let i = 0; i < 4; i += 1) { xs.push(seed + BigInt(i)); }
	return xs;
}

function show(label: string, xs: bigint[]): void {
	console.log(`${label} ${xs.length} ${xs.join(",")}`);
}

const seed = 100000000000000000000n;
const xs = build(seed);
const sliced = xs.slice(1, 3);
const joined = xs.concat(sliced);
const spread = [...xs, seed];
const filled: bigint[] = [0n, 0n, 0n];
filled.fill(seed);
xs.splice(1, 1, seed);
xs.splice(0, 1);
const mapped = xs.map((x: bigint): bigint => x + 1n);
const filtered = joined.filter((x: bigint): boolean => x > seed);
const reversed = joined.slice().reverse();
joined.length = 2;
spread.pop();
spread.shift();
show("xs", xs);
show("sliced", sliced);
show("joined", joined);
show("spread", spread);
show("filled", filled);
show("mapped", mapped);
show("filtered", filtered);
show("reversed", reversed);
console.log(`${xs.includes(seed)} ${spread.indexOf(seed + 3n)}`);
