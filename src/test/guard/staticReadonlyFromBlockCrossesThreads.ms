// INVARIANT: ULTRALOCK V0 with PARALOCK I22 (a static block's readonly write is its initializer).
// RED MEANS: a read of a block-assigned static readonly from another thread is refused.
// GUARD-JS

import { exit } from "std/process";

class Cfg {
	static readonly base: int32 = 0;
	static readonly xs: Readonly<int32[]> = [1, 2];
	static readonly ys: Readonly<int32[]> = [];
	static { Cfg.base = 21; Cfg.ys = [3, 4]; }
}

actor Reader {
	read(): int32 { return Cfg.base + Cfg.xs[1] + Cfg.ys[1] - 6; }
}

const doubled = spawn((): int32 => Cfg.base * 2 + Cfg.xs[0] + Cfg.ys[0] - 4);
const reader = new Reader();
const fromTask = await doubled;
const fromActor = await reader.read();
if (fromTask != 42 || fromActor != 21) {
	console.log(`GUARD-FAIL task ${fromTask} actor ${fromActor}`);
	exit(1);
}
console.log("GUARD-OK");
