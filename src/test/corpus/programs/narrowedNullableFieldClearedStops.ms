// @exit: 1
// @stdout: member 'S' is not accessible for type 'S | null' using 'null'
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: a narrowed value-carried `S | null` field read after a call cleared it stops; it used to read 0 on C.

struct S { n: int32; }

class Box { x: S | null = { n: 1 }; }

function clear(b: Box): void { b.x = null; }

function run(): void {
	const b = new Box();
	if (b.x != null) {
		console.log(`before ${b.x.n}`);
		clear(b);
		console.log(`after ${b.x.n}`);
	}
}

run();
