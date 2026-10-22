// nim-guard: a timed spawn awaited where it is written still compiles and runs.
//
// INVARIANT (ULTRALOCK T2): the refusal of a timed spawn that is not the operand
//   of its await leaves the direct `await spawn(fn, { timeout })` accepted, with
//   its deadline, alongside a `{ move }` list, and a timed spawn inside an awaited
//   `Promise.all` of spawns.
//
// WHAT IT CATCHES: the refusal reaching the accepted shape.
//
// RED MEANS: the build failed, or a value or the timeout was wrong.

import { exit } from "std/process";

function slow(): int32 {
	const until = Date.now() + 2000;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 7;
	return 5;
}

function run(): int32 {
	const a = await spawn((): int32 => 1, { timeout: 1000 });
	const xs: int32[] = [2, 3];
	const b = await spawn((): int32 => xs[0] + xs[1], { timeout: 1000, move: [xs] });
	let timedOut = false;
	try { const c = await spawn(slow, { timeout: 20 }); console.log(`late ${c}`); } catch (e) { timedOut = true; }
	const g = await Promise.all([spawn((): int32 => 10, { timeout: 1000 }), spawn((): int32 => 20)]);
	return timedOut ? a + b + g[0] + g[1] : -1;
}

const r = run();
if (r != 36) {
	console.log(`wrong ${r}`);
	exit(1);
}
console.log("GUARD-OK");
