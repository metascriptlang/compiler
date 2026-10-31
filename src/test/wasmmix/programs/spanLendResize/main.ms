// @stdout: n=2 [1,2]
// @stdout: n=2 [true,false]
// @stdout: n=3 [3,2,3]
// @stdout: n=0 []
import { peekThen, peekFlagThen, doubleFirstThen } from "./spanLendResizeWasm";

function show(n: int32, items: string): void {
	console.log(`n=${n} [${items}]`);
}

let ints: Vec<int32> = [1, 2, 3, 4];
try {
	peekThen(ints, (first: int32): void => {
		if (first == 1) {
			ints.pop();
			ints.pop();
		}
	});
} catch {}
show(ints.length, ints.join(","));

let flags: Vec<boolean> = [true, false, true, false, true];
try {
	peekFlagThen(flags[1..4], (first: boolean): void => {
		if (!first) {
			flags.pop();
			flags.pop();
			flags.pop();
		}
	});
} catch {}
show(flags.length, flags.join(","));

let reals: Vec<float64> = [1.5, 2, 3, 4];
doubleFirstThen(reals[0..2], (k: int32): void => {
	if (k == 0) reals.pop();
});
show(reals.length, reals.join(","));

let drained: Vec<int32> = [7, 8, 9];
try {
	peekThen(drained, (first: int32): void => {
		if (first == 7) while (drained.length > 0) drained.pop();
	});
} catch {}
show(drained.length, drained.join(","));
