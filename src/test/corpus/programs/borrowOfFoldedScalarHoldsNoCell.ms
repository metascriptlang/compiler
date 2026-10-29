// @stdout: 8/5 15 true
// note: a Borrow of a constant scalar points at a frame temp holding the folded value, as C's compound literal does, so taking it in a function, on every pass of a top-level loop, or for a float or a boolean leaves nothing alive at exit.
function inFunction(): string {
	const n: int32 = 7;
	const bn: Borrow<int32> = n;
	const f: float64 = 2.5;
	const bf: Borrow<float64> = f;
	return `${bn + 1}/${bf * 2}`;
}
let total = 0;
for (let i = 0; i < 3; i += 1) {
	const k: int32 = 4;
	const bk: Borrow<int32> = k;
	total += bk + i;
}
const flag: boolean = true;
const bb: Borrow<boolean> = flag;
console.log(inFunction(), total, bb);
