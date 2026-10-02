struct SubscriptRow { w: int32; }

class SubscriptBag { cells: int32[] = [0, 0]; }

function `[]`(this r: SubscriptRow, i: int32): int32 { return r.w * 10 + i; }

function `[]`(this b: SubscriptBag, i: int32): int32 { return b.cells[i] + 1; }

function `[]=`(this b: SubscriptBag, i: int32, v: int32): void { b.cells[i] = v * 2; }

test "a struct subscript extension reads through its own declaration" {
	const r: SubscriptRow = { w: 2 };
	assert r[3] == 23;
}

test "a class subscript extension reads and writes through its own declaration" {
	const b = new SubscriptBag();
	b[1] = 5;
	assert b[1] == 11;
	assert b[0] == 1;
}
