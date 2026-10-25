// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its close entries)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: literal|close 1|param|close 2|let|close 3|inner|close 4|after|annotated|close 6|close 5|beside|close 9|close 7|view|close 8|end
// note: a value a cast makes of a distinct type with a destroy hook is owned by its local and destroyed at scope exit.

type Handle = distinct int32;
const log: string[] = [];
function onDestroy(this h: Handle): void { log.push("close " + (h as int32).toString()); }
function open(n: int32): Handle { return n as Handle; }

function literal(): void { const h = 1 as Handle; log.push("literal"); }
function fromParam(n: int32): void { const h = n as Handle; log.push("param"); }
function reassignable(n: int32): void { let h = n as Handle; log.push("let"); }
function inBlock(): void {
	{
		const h = 4 as Handle;
		log.push("inner");
	}
	log.push("after");
}
function annotated(): void { const a: Handle = 5 as Handle; const b = 6 as Handle; log.push("annotated"); }
function beside(): void { const c = open(7); const k = 9 as Handle; log.push("beside"); }
function sameType(h: Handle): void { const view = h as Handle; log.push("view"); }
function viaView(): void { const o = open(8); sameType(o); }

literal();
fromParam(2);
reassignable(3);
inBlock();
annotated();
beside();
viaView();
log.push("end");
console.log(log.join("|"));
