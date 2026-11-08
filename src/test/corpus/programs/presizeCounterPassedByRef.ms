// A push loop whose counter is passed to a ref or out parameter keeps the push loop's result: the call can move the
// counter forward or back, so the array is not presized to the source length (NIM-REF TR-41).
//
// @stdout: 1,2,8,9,10,11,12|1,10,11,12|1,2,3,4,2,3,4,5,6,7,8,9,10,11,12

function nums(n: int32): int32[] {
	const xs: int32[] = [];
	for (let k: int32 = 1; k <= n; k += 1) xs.push(k);
	return xs;
}

function skip(ref k: int64, by: int64): void { k += by; }
function setTo(out k: int64, v: int64): void { k = v; }

function skipped(xs: int32[]): string {
	const out: int32[] = [];
	for (let i: int64 = 0; i < (xs.length as int64); i += 1) {
		if (i == 2) skip(i, 5);
		out.push(xs[i]);
	}
	return out.join(",");
}

function jumped(xs: int32[]): string {
	const out: int32[] = [];
	for (let i: int64 = 0; i < (xs.length as int64); i += 1) {
		if (i == 1) setTo(out i, 9);
		out.push(xs[i]);
	}
	return out.join(",");
}

function rewound(xs: int32[]): string {
	const out: int32[] = [];
	let once = true;
	for (let i: int64 = 0; i < (xs.length as int64); i += 1) {
		{
			if (i == 4 && once) {
				once = false;
				skip(i, -3);
			}
		}
		out.push(xs[i]);
	}
	return out.join(",");
}

console.log(skipped(nums(12)) + "|" + jumped(nums(12)) + "|" + rewound(nums(12)));
