// @columns: mixed
// @stdout: threw a kept callback was called while 'bump' holds a copy of its ref parameter 'total', so JS would see the variable as it was before the call and a write to it would be lost: call the callback from a function without ref or out parameters
// @stdout: 2
// @stdout: 3
import { listen, bump, forget } from "./keptCallbackDuringRefWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let total: int32 = 1;
listen((n: int32): void => {
	total = 50;
});
console.log(attempt((): void => {
	bump(total);
}));
console.log(`${total}`);
forget();
bump(total);
console.log(`${total}`);
