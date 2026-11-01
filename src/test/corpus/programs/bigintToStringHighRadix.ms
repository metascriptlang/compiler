// @stdout: radix 3 7 10 13 17 20 32 36 digest 133288 zeros 0 0 -1 z -z 10 -10
// note: bigint toString(radix) above 16 agrees digit for digit across sizes, around radix powers and for negatives; the digest folds the text of every value.

function digestOf(text: string, seed: number): number {
	let h = seed;
	for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 1000003;
	return h;
}

let h: number = 7;
const radixes: int32[] = [3, 7, 10, 13, 17, 20, 32, 36];
for (const radix of radixes) {
	const r = BigInt(radix);
	let pow = 1n;
	for (let i = 0; i < 40; i++) {
		pow = pow * r;
		for (const d of [-1n, 0n, 1n]) {
			const v = pow + d;
			h = digestOf(v.toString(radix), h);
			h = digestOf((-v).toString(radix), h);
		}
	}
	let x = 1n;
	for (let i = 1; i < 120; i++) {
		x = x * 1000003n + BigInt(i);
		h = digestOf(x.toString(radix), h);
	}
}
console.log(`radix 3 7 10 13 17 20 32 36 digest ${h} zeros ${0n.toString(17)} ${(-0n).toString(20)} ${(-1n).toString(36)} ${35n.toString(36)} ${(-35n).toString(36)} ${36n.toString(36)} ${(-36n).toString(36)}`);
