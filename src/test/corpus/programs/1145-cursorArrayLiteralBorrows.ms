// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0) (inbox 2026-10-21-raiser-never-runs-a-class-ondestroy)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: cursor-array-literal const=1 arg=1 pair=2 owned=1 total=5
let destroyed = 0;
class Cell { n: int32 = 0; }
function onDestroy(this c: Cell): void { destroyed += 1; }

function depth(c: Readonly<Cell>, open: Cursor<Readonly<Cell>>[]): int32 { return open.length as int32 + c.n; }
function asConst(c: Readonly<Cell>): int32 { const open: Cursor<Readonly<Cell>>[] = [c]; return depth(c, open); }
function asArgument(c: Readonly<Cell>): int32 { return depth(c, [c]); }
function asPair(a: Readonly<Cell>, b: Readonly<Cell>): int32 { const open: Cursor<Readonly<Cell>>[] = [a, b]; return depth(a, open); }
function owned(c: Cell): int32 { const kept: Cell[] = [c]; return kept.length as int32; }

function count(run: () => void): int32 {
	const before = destroyed;
	run();
	return destroyed - before;
}

let out = "cursor-array-literal";
out += ` const=${count((): void => { const c = new Cell(); asConst(c); })}`;
out += ` arg=${count((): void => { const c = new Cell(); asArgument(c); })}`;
out += ` pair=${count((): void => { const a = new Cell(); const b = new Cell(); asPair(a, b); })}`;
out += ` owned=${count((): void => { const c = new Cell(); owned(c); })}`;
out += ` total=${destroyed}`;
console.log(out);
