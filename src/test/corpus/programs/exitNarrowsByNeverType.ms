// @stdout: ok 5 checked 6
// @exit: 7
// note: `exit` and `process.exit` stop the program because their declared return type is `never`: the path through them leaves the flow, so a guard that exits narrows what follows, and the program ends with the code `process.exit` was given.

import { exit } from "std/process";

type Got = { ok: true, value: int32 } | { ok: false, err: string };

function get(n: int32): Got {
	return n > 0 ? { ok: true, value: n } : { ok: false, err: "negative" };
}

const r = get(5);
if (!r.ok) {
	exit(1);
}
const head = `ok ${r.value}`;

function checked(n: int32): int32 {
	const g = get(n);
	if (!g.ok) {
		process.exit(2);
	}
	return g.value + 1;
}
console.log(`${head} checked ${checked(5)}`);
process.exit(7);
