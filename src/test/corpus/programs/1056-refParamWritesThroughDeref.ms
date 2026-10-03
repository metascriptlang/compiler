// @xfail(raiser): raiser runtime error: cannot assign through a pointer or ref parameter at comptime: the Raiser VM writes in place only into a struct or an array
// @stdout: ptr=11 30 31 retarget=2 ints=9 z points=9 4 3 bag=77 reads=4 2

struct Cell { v: int32; }
struct Pt { x: int32; }
struct Bag { items: int32[]; }
struct Reader { bytes: uint8[]; offset: int32; }

function setField(ref q: Ptr<Cell>): void { q[].v = 11; }
function setWhole(ref q: Ptr<Cell>, x: int32): void { q[] = { v: x }; }
function bumpField(ref q: Ptr<Cell>): void { q[].v = q[].v + 1; }
function retarget(ref q: Ptr<Cell>, other: Ptr<Cell>): void { q = other; }
function putInt(ref arr: int32[]): void { arr[0] = 9; }
function putString(ref s: string[]): void { s[0] = "z"; }
function setPoints(ref ps: Pt[]): void { ps[0] = { x: 9 }; ps[1].x = 4; }
function grow(ref ps: Pt[]): void { ps.push({ x: 1 }); }
function poke(this ref b: Bag): void { b.items[0] = 77; }
function next(this ref r: Reader): uint8 {
	const value = r.bytes[r.offset];
	r.offset += 1;
	return value;
}
function remaining(this ref r: Reader): int32 { return r.bytes.length - r.offset; }

function main(): void {
	let c: Cell = { v: 2 };
	let p: Ptr<Cell> = c as Ptr<Cell>;
	setField(p);
	const a = c.v;
	setWhole(p, 30);
	const b = c.v;
	bumpField(p);
	let other: Cell = { v: 2 };
	retarget(p, other as Ptr<Cell>);
	let ints: int32[] = [1, 2];
	let strs: string[] = ["a"];
	putInt(ints);
	putString(strs);
	let ps: Pt[] = [{ x: 1 }, { x: 2 }];
	setPoints(ps);
	grow(ps);
	let bag: Bag = { items: [1, 2] };
	bag.poke();
	let reader: Reader = { bytes: [4, 5, 6], offset: 0 };
	const first = reader.next();
	console.log(`ptr=${a} ${b} ${c.v} retarget=${p[].v} ints=${ints[0]} ${strs[0]} points=${ps[0].x} ${ps[1].x} ${ps.length} bag=${bag.items[0]} reads=${first} ${reader.remaining()}`);
}

main();
