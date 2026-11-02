// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: pushed=0 chain=3 mutable=2,1 owned=1
let destroyed = 0;
class Cell { n: int32 = 0; next: Cell | null = null; }
function onDestroy(this c: Cell): void { destroyed += 1; }

function pushed(c: Readonly<Cell>): int32 {
	const open: Cursor<Readonly<Cell>>[] = [];
	open.push(c);
	return open.length as int32;
}
function chain(start: Readonly<Cell>): int32 {
	const open: Cursor<Readonly<Cell>>[] = [];
	open.push(start);
	let total = 0;
	while (open.length > 0) {
		const c = open.pop()!;
		total += c.n;
		if (c.next != null) open.push(c.next);
	}
	return total;
}
function mutable(): int32 {
	const c = new Cell();
	c.n = 2;
	const open: Cursor<Cell>[] = [];
	open.push(c);
	open.push(c);
	return open[0].n;
}
function owned(): void { const c = new Cell(); const kept: Cell[] = []; kept.push(c); kept.length; }

const a = new Cell();
a.n = 1;
a.next = new Cell();
a.next.n = 2;
const before = destroyed;
pushed(a);
const afterPush = destroyed - before;
const total = chain(a);
const mark = destroyed;
const m = mutable();
const afterMutable = destroyed - mark;
const mark2 = destroyed;
owned();
console.log(`pushed=${afterPush} chain=${total} mutable=${m},${afterMutable} owned=${destroyed - mark2}`);
