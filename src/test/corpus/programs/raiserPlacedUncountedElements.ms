// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: literal=1 pair=2 owned=1
let destroyed = 0;
class Cell { n: int32 = 0; }
function onDestroy(this c: Cell): void { destroyed += 1; }

function lengthOf(open: Cursor<Readonly<Cell>>[]): int32 { return open.length as int32; }

function literal(): void { const c = new Cell(); const open: Cursor<Readonly<Cell>>[] = [c]; lengthOf(open); }
function pair(): void {
	const a = new Cell();
	const b = new Cell();
	const open: Cursor<Readonly<Cell>>[] = [a, b];
	lengthOf(open);
}
function owned(): void { const c = new Cell(); const kept: Cell[] = [c]; kept.length; }

literal();
const afterLiteral = destroyed;
pair();
const afterPair = destroyed;
owned();
console.log(`literal=${afterLiteral} pair=${afterPair - afterLiteral} owned=${destroyed - afterPair}`);
