// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (end n2, end b2)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
struct Res {
	id: int32;
	name: string;
}

struct BigRes {
	id: int32;
	name: string;
	a: int64;
	b: int64;
	c: int64;
	d: int64;
}

function onDestroy(this self: Res): void {
	console.log("destroy " + self.id.toString());
}

function onDestroy(this self: BigRes): void {
	console.log("big destroy " + self.id.toString() + " " + self.d.toString());
}

function mk(i: int32): Res {
	return { id: i, name: "n" + i.toString() };
}

function mkBig(i: int32): BigRes {
	return { id: i, name: "b" + i.toString(), a: 1, b: 2, c: 3, d: 40 + i };
}

function small(): void {
	let r: Res = mk(1);
	r = mk(2);
	console.log("end " + r.name);
}

function big(): void {
	let r: BigRes = mkBig(1);
	r = mkBig(2);
	console.log("end " + r.name);
}

small();
big();
