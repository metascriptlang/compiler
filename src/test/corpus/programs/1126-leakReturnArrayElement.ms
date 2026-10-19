// @maxrss: 30
// @stdout: leak-return-array-element 1200000 1200000 1200000 1200000
struct Slot { text: string; n: int32 }
class Plain {
	items: Slot[] = [];
	at(i: int32): Slot { return this.items[i]; }
}
class Box<T> {
	items: T[] = [];
	at(i: int32): T { return this.items[i]; }
}
class Grid {
	rows: Slot[][] = [[]];
	at(r: int32, c: int32): Slot { return this.rows[r][c]; }
}
function first(xs: Slot[]): Slot { return xs[0]; }

const pad = "x".repeat(160);
const p = new Plain();
const b = new Box<Slot>();
const g = new Grid();
const xs: Slot[] = [];
p.items.push({ text: "", n: 0 });
b.items.push({ text: "", n: 0 });
g.rows[0].push({ text: "", n: 0 });
xs.push({ text: "", n: 0 });
let viaPlain = 0;
let viaBox = 0;
let viaGrid = 0;
let viaFn = 0;
for (let k = 0; k < 200000; k++) {
	const text = `${k} ${pad}`;
	p.items[0] = { text, n: 1 };
	b.items[0] = { text, n: 2 };
	g.rows[0][0] = { text, n: 3 };
	xs[0] = { text, n: 4 };
	viaPlain += p.at(0).n * 6 / 1;
	viaBox += b.at(0).n * 3;
	viaGrid += g.at(0, 0).n * 2;
	viaFn += first(xs).n * 3 / 2;
}
console.log("leak-return-array-element", viaPlain, viaBox, viaGrid, viaFn);
