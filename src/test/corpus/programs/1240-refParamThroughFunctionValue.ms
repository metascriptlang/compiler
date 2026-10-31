// @stdout: 2 12 7 9 5

class Holder { cb: (ref x: int32) => void; constructor(cb: (ref x: int32) => void) { this.cb = cb; } }
class Cell { n: int32; constructor(n: int32) { this.n = n; } }

function bump(ref x: int32): void { x = x + 1; }
function addTen(ref x: int32): void { x = x + 10; }
function setSeven(out x: int32): void { x = 7; }
function replace(ref c: Cell): void { c = new Cell(9); }
function visit(f: (ref x: int32) => void): int32 { let v: int32 = 1; f(v); return v; }
function visitOut(f: (out x: int32) => void): int32 { let v: int32; f(v); return v; }
function visitCell(f: (ref c: Cell) => void): int32 { let c = new Cell(1); f(c); return c.n; }

function main(): void {
	const direct = visit(bump);
	const local: (ref x: int32) => void = addTen;
	let w: int32 = 2;
	local(w);
	const held = new Holder(bump);
	let h: int32 = 4;
	held.cb(h);
	console.log(`${direct} ${w} ${visitOut(setSeven)} ${visitCell(replace)} ${h}`);
}
main();
