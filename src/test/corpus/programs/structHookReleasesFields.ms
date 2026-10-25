// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its @stdout line)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: field outer=100 inner=100
// @stdout: array outer=100 inner=300
// @stdout: nested outer=100 inner=100
// @stdout: generic outer=100 inner=100
// note: a struct's own onDestroy runs, then the struct's fields are released, as a class's are (old compiler: the hook replaced the release, inner=0 on every line)

let inner = 0;
let outer = 0;

class Inner { v: int32 = 1; }
function onDestroy(this x: Inner): void { inner += 1; }

struct WithField { name: string; child: Inner; }
function onDestroy(this x: WithField): void { outer += 1; }

struct WithArray { children: Inner[]; }
function onDestroy(this x: WithArray): void { outer += 1; }

struct Mid { child: Inner; }
struct WithNested { mid: Mid; }
function onDestroy(this x: WithNested): void { outer += 1; }

struct Box<T> { value: T; }
function onDestroy<T>(this x: Box<T>): void { outer += 1; }

function reset(): void {
	inner = 0;
	outer = 0;
}

function field(i: int32): void {
	const o: WithField = { name: "n" + `${i}`.repeat(20), child: new Inner() };
	if (o.child.v != 1) console.log("bad");
}

function array(): void {
	const o: WithArray = { children: [new Inner(), new Inner(), new Inner()] };
	if (o.children.length != 3) console.log("bad");
}

function nested(): void {
	const o: WithNested = { mid: { child: new Inner() } };
	if (o.mid.child.v != 1) console.log("bad");
}

function generic(): void {
	const o: Box<Inner> = { value: new Inner() };
	if (o.value.v != 1) console.log("bad");
}

for (let i = 0; i < 100; i += 1) field(i);
console.log(`field outer=${outer} inner=${inner}`);
reset();
for (let i = 0; i < 100; i += 1) array();
console.log(`array outer=${outer} inner=${inner}`);
reset();
for (let i = 0; i < 100; i += 1) nested();
console.log(`nested outer=${outer} inner=${inner}`);
reset();
for (let i = 0; i < 100; i += 1) generic();
console.log(`generic outer=${outer} inner=${inner}`);
