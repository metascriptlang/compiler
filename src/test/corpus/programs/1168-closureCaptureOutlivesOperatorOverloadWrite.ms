// @stdout: 7
// @stdout: 107
// note: a declared operator that empties the array a closure's capture was read from, called through a routine and written in the capturing routine itself; the capture stays counted in both.
class Box { v: int32 = 7; }
class Wrapper { items: Box[] = []; }
class Pad { v: int32 = 99; }
function `+`(this w: Wrapper, n: int32): Wrapper { w.items = []; return w; }
function hidden(w: Wrapper): void { w + 1; }
function viaCallee(w: Wrapper): void {
	const item = w.items[0];
	const f = (): int32 => item.v;
	hidden(w);
	const pads: Pad[] = [];
	for (let i = 0; i < 64; i++) pads.push(new Pad());
	console.log(f());
}
function inPlace(w: Wrapper): void {
	const item = w.items[0];
	const f = (): int32 => item.v;
	w + 1;
	const pads: Pad[] = [];
	for (let i = 0; i < 64; i++) pads.push(new Pad());
	console.log(f() + 100);
}
function run(): void {
	const a = new Wrapper();
	a.items.push(new Box());
	viaCallee(a);
	const b = new Wrapper();
	b.items.push(new Box());
	inPlace(b);
}
run();
