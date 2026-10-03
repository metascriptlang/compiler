// @xfail(raiser): error: Cannot resolve module 'std/actor'
// @serial
// @stdout: holder spawned true
// @stdout: local spawned 1
// @stdout: watched terminated n=7
// @exit: 0
// note: an actor that declares no message method still gets a dispatch, empty, so its constructor can create the pid. Before, main wired an undeclared `<Actor>_dispatch` (C compile error) and the origin merge threw an internal error at the declaration. A message no case handles falls through the dispatch the same way here as in an actor with methods.

import { stop, ExitReason } from "std/actor";

actor Unused {
	count: int32 = 0;
}

actor Holder {
	label: string = "";
	constructor(label: string) { this.label = label; }
}

actor Watched {
	n: int32 = 7;
	onTerminate(reason: ExitReason): void { console.log(`watched terminated n=${this.n}`); }
}

function local(): number {
	actor Inner { x: number = 1 }
	const i = new Inner();
	const up = i.pid != 0 ? 1 : 0;
	stop(i.pid, ExitReason.Normal);
	return up;
}

const h = new Holder("shelf");
console.log(`holder spawned ${h.pid != 0}`);
stop(h.pid, ExitReason.Normal);
console.log(`local spawned ${local()}`);
const w = new Watched();
stop(w.pid, ExitReason.Normal);
