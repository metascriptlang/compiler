// @exit: 1
// @stdout: member 'S' is not accessible for type 'S | null' using 'null'
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: a narrowed `o.b.x` (value-carried `S | null`) read after a method cleared it stops; it used to read 0 on C.

struct S { n: int32; }

class Box {
	x: S | null = { n: 1 };
	clear(): void { this.x = null; }
}

class Outer { b: Box = new Box(); }

function run(): void {
	const o = new Outer();
	if (o.b.x != null) {
		console.log(`before ${o.b.x.n}`);
		o.b.clear();
		console.log(`after ${o.b.x.n}`);
	}
}

run();
