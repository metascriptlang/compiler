// @columns: mixed
// @stdout: threw a kept callback was called while 'bump' holds a copy of its Span, so a JS write to the array would be lost: take a Vec in 'bump', or call the callback from a function without a Span
// @stdout: 2,2
// @stdout: 3,2
import { listen, bump, forget } from "./keptCallbackDuringSpanWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let ns: Vec<int32> = [1, 2];
listen((n: int32): void => {
	ns[1] = 50;
});
console.log(attempt((): void => {
	bump(ns);
}));
console.log(ns.join(","));
forget();
bump(ns);
console.log(ns.join(","));
