// @exit: 1
// @stdout: member 'S' is not accessible for type 'S | null' using 'null'
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: a narrowed local `S | null` read after a closure cleared it stops; it used to read 0 on C.

struct S { n: int32; }

function make(on: boolean): S | null {
	if (on) return { n: 5 };
	return null;
}

function each(f: () => void): void { f(); }

function run(): void {
	let s: S | null = make(true);
	if (s != null) {
		console.log(`before ${s.n}`);
		each((): void => { s = null; });
		console.log(`after ${s.n}`);
	}
}

run();
