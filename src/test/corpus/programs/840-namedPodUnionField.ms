type N = int32 | float64;

struct S {
	n: N;
	s: string;
}

class C {
	n: N = 1 as int32;
	s: string = "";
}

function mk(i: int32): string { return "v" + i.toString(); }

function run(): void {
	let a: S = { n: 5 as int32, s: mk(1) };
	const b: S = a;
	a = { n: 2.5, s: mk(2) };
	console.log(b.s + " " + a.s + " " + (b.n as int32).toString());
	const c = new C();
	c.s = mk(3);
	c.n = 7 as int32;
	const d: N = c.n;
	console.log(c.s + " " + (d as int32).toString());
}
run();
