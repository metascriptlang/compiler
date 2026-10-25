// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its destroy entries)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: in 1|destroy plain 1|in 2|destroy block 2|in 3|destroy shared 3|in 4|destroy fd 4|in 5|destroy local 5|end
// note: a lifecycle hook declared in a function or block body binds its type like a module-level one.

struct Plain { v: int32; }
struct InBlock { v: int32; }
class Shared { v: int32 = 0; constructor(v: int32) { this.v = v; } }
type Fd = distinct int32;
const log: string[] = [];

function installPlain(): void {
	function onDestroy(this x: Plain): void { log.push("destroy plain " + x.v.toString()); }
}
function installInBlock(): void {
	{
		function onDestroy(this x: InBlock): void { log.push("destroy block " + x.v.toString()); }
	}
}
function installShared(): void {
	function onDestroy(this x: Shared): void { log.push("destroy shared " + x.v.toString()); }
}
function installFd(): void {
	function onDestroy(this x: Fd): void { log.push("destroy fd " + (x as int32).toString()); }
}

function open(n: int32): Fd { return n as Fd; }

function plain(): void { const p: Plain = { v: 1 }; log.push("in " + p.v.toString()); }
function inBlock(): void { const b: InBlock = { v: 2 }; log.push("in " + b.v.toString()); }
function shared(): void { const s = new Shared(3); log.push("in " + s.v.toString()); }
function fd(): void { const f = open(4); log.push("in " + (f as int32).toString()); }
function local(): void {
	struct Local { v: int32; }
	function onDestroy(this x: Local): void { log.push("destroy local " + x.v.toString()); }
	const l: Local = { v: 5 };
	log.push("in " + l.v.toString());
}

plain();
inBlock();
shared();
fd();
local();
log.push("end");
console.log(log.join("|"));
