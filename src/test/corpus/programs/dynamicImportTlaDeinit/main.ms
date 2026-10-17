// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM runs no user lifecycle hooks, as JS has no destructors
// @stdout: slow start
// @stdout: quick body
// @stdout: slow end
// @stdout: loaded slow quick
// @stdout: steps slow start quick body slow end
// @stdout: destroy order quick slow slow early eager
//
// A module with a top-level await is torn down at exit like any module reached through
// import(): in the reverse of the order the bodies started. `quick` starts while `slow`
// awaits (the steps line), so it goes first, then every value `slow` set before and after
// its await, then the modules the program initialized at startup.

import { held } from "./eager";
import { steps } from "./tracker";

async function run(): Promise<void> {
	const s = import("./slow");
	await sleepAsync(1);
	const q = await import("./quick");
	const sm = await s;
	console.log(`loaded ${sm.held.name} ${q.held.name}`);
	console.log(`steps${steps()}`);
}

if (held.name != "eager") console.log("unexpected");
run();
