// @stdout: lit=abcdcd/6 live=lv-tail/lv-tail last=ls-tail mv=mv-tail call=call-tail nest=ns-tail/7 kept=abcdcd
// @skip-js: Arc<T> has no js binding (the atomic-rc box is C-only)
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: `new Arc(v)` owns its payload. A struct holding a heap string reaches the cell from every source form: a literal over a live or a dead heap string, a named value still read after the box, a last read, an explicit `move`, a call result, and a struct nested in the payload. Each must leave one owner, so the string is freed once: before the fix the boxed temporary was also destroyed at scope end and drc/orc exited 133 (heap-use-after-free in msStringDestroy under ASan).

struct Payload { buf: string; n: int32; }
struct Outer { inner: Payload; k: int32; }

function mk(x: string): string { return x + "-tail"; }
function makePayload(): Payload { return { buf: mk("call"), n: 3 }; }

function main(): void {
	const s = "ab" + "cd".repeat(2);
	const lit: Arc<Payload> = new Arc({ buf: s, n: 4 });
	const dead: Arc<Payload> = new Arc({ buf: "ab" + "cd".repeat(2), n: 6 });

	const p: Payload = { buf: mk("lv"), n: 1 };
	const live: Arc<Payload> = new Arc(p);

	const q: Payload = { buf: mk("ls"), n: 2 };
	const last: Arc<Payload> = new Arc(q);

	const r: Payload = { buf: mk("mv"), n: 2 };
	const mv: Arc<Payload> = new Arc(move r);

	const call: Arc<Payload> = new Arc(makePayload());

	const o: Outer = { inner: { buf: mk("ns"), n: 5 }, k: 7 };
	const nest: Arc<Outer> = new Arc(o);

	console.log(`lit=${lit.buf}/${dead.n} live=${live.buf}/${p.buf} last=${last.buf} mv=${mv.buf} call=${call.buf} nest=${nest.inner.buf}/${nest.k} kept=${s}`);
}
main();
