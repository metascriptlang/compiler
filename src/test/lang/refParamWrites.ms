struct Cell695 { v: int32; }

function setField(ref q: Ptr<Cell695>): void { q[].v = 11; }
function setWhole(ref q: Ptr<Cell695>, x: int32): void { q[] = { v: x }; }
function bumpField(ref q: Ptr<Cell695>): void { q[].v = q[].v + 1; }
function retarget(ref q: Ptr<Cell695>, other: Ptr<Cell695>): void { q = other; }

test "refParamWrites: writes through q[] on a ref Ptr parameter" {
	let c: Cell695 = { v: 2 };
	let p: Ptr<Cell695> = c as Ptr<Cell695>;
	setField(p);
	assert c.v == 11;
	setWhole(p, 30);
	assert c.v == 30;
	bumpField(p);
	assert c.v == 31;
}

test "refParamWrites: reassigning a ref Ptr parameter retargets the caller's pointer" {
	let a: Cell695 = { v: 1 };
	let b: Cell695 = { v: 2 };
	let p: Ptr<Cell695> = a as Ptr<Cell695>;
	retarget(p, b as Ptr<Cell695>);
	assert p[].v == 2;
}

struct Pt696 { x: int32; }
struct Bag696 { items: int32[]; }

function putInt(ref arr: int32[]): void { arr[0] = 9; }
function putString(ref s: string[]): void { s[0] = "z"; }
function setPoints(ref ps: Pt696[]): void { ps[0] = { x: 9 }; ps[1].x = 4; }
function grow(ref ps: Pt696[]): void { ps.push({ x: 1 }); }
function poke(this ref b: Bag696): void { b.items[0] = 77; }

test "refParamWrites: element stores through a ref array parameter" {
	let a: int32[] = [1, 2];
	let t: string[] = ["a"];
	putInt(a);
	putString(t);
	assert a[0] == 9;
	assert t[0] == "z";
}

test "refParamWrites: struct elements, push and a this ref field through a ref parameter" {
	let ps: Pt696[] = [{ x: 1 }, { x: 2 }];
	setPoints(ps);
	grow(ps);
	assert ps[0].x == 9;
	assert ps[1].x == 4;
	assert ps.length == 3;
	let bag: Bag696 = { items: [1, 2] };
	bag.poke();
	assert bag.items[0] == 77;
}
