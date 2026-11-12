// @exit: 1
// @stdout: start 12
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the product wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a store loop whose source and destination are one array under two names runs only its checked loop: a
// sticky block would double in place, and its checked rerun would read the doubled values, where 1610612736 * 2
// overflows but its wrapped -1073741824 * 2 does not, so the program would go on with every value doubled twice.

function doubleInto(src: int32[], dst: int32[]): void {
	for (let i = 0; i < src.length; i++) dst[i] = src[i] * 2;
}

function sum(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const x of xs) t += x;
	return t;
}

const small: int32[] = [1, 2, 3];
doubleInto(small, small);
console.log(`start ${sum(small)}`);
const xs: int32[] = [];
for (let k: int32 = 0; k < 3000; k++) xs.push(1);
xs[1500] = 1610612736;
const same = xs;
doubleInto(xs, same);
console.log(sum(xs));
console.log("unreachable");
