// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM runs no user lifecycle hooks, as JS has no destructors
// @stdout: second body
// @stdout: first body
// @stdout: loaded second first
// @stdout: destroy order first second eager
//
// A module reached through import() is torn down at exit only when its body ran, in the
// reverse of the order the bodies actually ran (second, then first), before the modules
// the program initialized at startup. The source names `first` before `second`, so the
// module order alone would tear `second` down first. `never` is imported by nobody at run time.

import { held } from "./eager";

async function later(): Promise<string> {
	const f = await import("./first");
	return f.held.name;
}

async function run(): Promise<void> {
	const s = await import("./second");
	const f = await later();
	console.log(`loaded ${s.held.name} ${f}`);
}

async function unused(): Promise<void> {
	const n = await import("./never");
	console.log(n.held.name);
}

if (held.name != "eager") console.log("unexpected");
run();
