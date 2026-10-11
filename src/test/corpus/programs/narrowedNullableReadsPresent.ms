// note: a narrowed value-carried `T | null` read that nothing cleared reads its value, past calls, methods, closures and nested owners.

struct S { n: int32; }

class Box {
	x: S | null = { n: 1 };
	y: int32 | null = 2;
	keep(): void { }
}

class Outer { b: Box = new Box(); }

function make(on: boolean): S | null {
	if (on) return { n: 5 };
	return null;
}

function keep(b: Box): void { }

function each(f: () => void): void { f(); }

function run(): void {
	const b = new Box();
	if (b.x != null) {
		keep(b);
		console.log(`call ${b.x.n}`);
	}
	if (b.x != null) {
		b.keep();
		console.log(`method ${b.x.n + 1}`);
	}
	if (b.y != null) {
		each((): void => { });
		console.log(`closure ${b.y + 1}`);
	}
	const o = new Outer();
	if (o.b.x != null) {
		o.b.keep();
		console.log(`nested ${o.b.x.n + 2}`);
	}
	let s: S | null = make(true);
	if (s != null) {
		each((): void => { });
		console.log(`local ${s.n}`);
	}
	let t = 0;
	const x = b.x;
	if (x != null) {
		for (let i = 0; i < 4; i++) t += x.n;
	}
	console.log(`loop ${t}`);
}

run();
