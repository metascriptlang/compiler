// @stdout: call true
// @stdout: compound 10 calls 3
// @stdout: field 4 0
// @stdout: nested 3
// @stdout: method 7
// @stdout: local 9
// @stdout: ref 0
// @stdout: read 2
struct Cell { x: int32; y: int32; }
class Grid {
	slots: Vec<int32> = [0, 0, 0, 0];
	base: int32 = 1;
	at(a: int32): int32 { return a + this.base; }
	put(a: int32): void { this.slots[this.at(a)] = 7; }
}
struct Pool { slots: Vec<int32>; }
function slotIndex(this p: Pool, id: uint32): int32 { return (id & 0xff) as int32; }
function free(ref pool: Pool, id: uint32): void { pool.slots[pool.slotIndex(id)] = pool.slots[0]; }

let wanted: Vec<boolean> = [false, false, false, false];
let counts: Vec<int32> = [0, 0, 0, 0];
let cells: Vec<Cell> = [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }];
let grid: Vec<Vec<int32>> = [[0, 0], [0, 0]];
let calls = 0;
function slotOf(a: int32): int32 { calls += 1; return a + 1; }

function want(a: int32): void { wanted[slotOf(a)] = true; }
function bump(a: int32): void { counts[slotOf(a)] += 5; }
function paint(a: int32): void { cells[slotOf(a)].x = 4; }
function mark(a: int32): void { grid[a][slotOf(a)] = 3; }
function local(): string {
	let v: Vec<int32> = [0, 0, 0];
	v[slotOf(0)] = 9;
	return `local ${v[1]}`;
}

want(0);
console.log(`call ${wanted[1]}`);
bump(0);
bump(0);
console.log(`compound ${counts[1]} calls ${calls}`);
paint(1);
console.log(`field ${cells[2].x} ${cells[2].y}`);
mark(0);
console.log(`nested ${grid[0][1]}`);
const g = new Grid();
g.put(1);
console.log(`method ${g.slots[2]}`);
console.log(local());
let pool: Pool = { slots: [0, 5, 6] };
free(pool, 1);
console.log(`ref ${pool.slots[1]}`);
const r: Vec<int32> = [1, 2, 3];
console.log(`read ${r[slotOf(0)]}`);
