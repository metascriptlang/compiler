// @stdout: threw stop
// @stdout: 7,2,3
// @stdout: 8,3,4
// @stdout: 7
// @stdout: 1007
// @stdout: threw first
// @stdout: 21
// @stdout: 1007
// @stdout: 7,8,4
import { editStop, peek, sumOf, bump } from "./spanThrowLentWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let ns: Vec<int32> = [1, 2, 3];
console.log(attempt((): void => {
	editStop(ns, true);
}));
console.log(ns.join(","));
bump(ns);
console.log(ns.join(","));

let big: Vec<int32> = [];
for (let i = 0; i < 1000; i += 1) big.push(0);
for (let k = 0; k < 30; k += 1) {
	attempt((): void => {
		editStop(big, true);
	});
}
console.log(`${sumOf(big)}`);
bump(big);
console.log(`${sumOf(big)}`);

console.log(attempt((): void => {
	peek(big, (first: int32): int32 => {
		throw new Error("first");
	});
}));
console.log(`${peek(big, (first: int32): int32 => first + 13)}`);
for (let k = 0; k < 30; k += 1) {
	attempt((): void => {
		peek(big, (first: int32): int32 => {
			throw new Error("again");
		});
	});
}
console.log(`${sumOf(big)}`);
editStop(ns[0..2], false);
console.log(ns.join(","));
