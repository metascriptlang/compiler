// @stdout: 6:3|abc:3|6:3|abc:3
// note: a closure environment belongs to the module that declares its function. Two modules
// each with a function `trav` capturing different variables must not share one environment layout.
import { trav as libTrav } from "./lib";

function trav(items: int32[]): string {
	let total = 0;
	let count = 0;
	const add = (n: int32): void => {
		total = total + n;
		count = count + 1;
	};
	for (const n of items) add(n);
	return `${total}:${count}`;
}

const out: string[] = [];
for (let i = 0; i < 2; i += 1) {
	out.push(trav([1, 2, 3]));
	out.push(libTrav(["a", "b", "c"]));
}
console.log(out.join("|"));
