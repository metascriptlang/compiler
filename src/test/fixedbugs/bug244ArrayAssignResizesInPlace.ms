// Symptom: on JS `p[] = [3, 4, 5]` through a `Ptr<Vec<int32>>` to a two-element Vec left it at length 2, and a whole struct assignment left a pointer to its Vec field on the old array (C: the new contents).
// Root cause: the JS in-place assignment of an array returned a fresh copy when the lengths differed; through a pointer nobody stored that copy, and at a field it replaced the array every pointer still held.
// Fix: an array assigned in place takes the source length and then each element, as a sequence copy does; only an empty destination takes a copy.
struct Bag244 { tags: Vec<int32>; n: int32; }

test "bug244: a Vec assigned through a pointer grows and shrinks in place" {
	let v: Vec<int32> = [1, 2];
	const p = v as Ptr<Vec<int32>>;
	p[] = [3, 4, 5];
	assert v.length == 3;
	assert v[2] == 5;
	p[] = [9];
	assert v.length == 1;
	assert p[][0] == 9;
}

test "bug244: a Vec of the same length is written element by element" {
	let v: Vec<int32> = [1, 2];
	const p = v as Ptr<Vec<int32>>;
	p[] = [7, 8];
	assert v[0] == 7;
	assert v[1] == 8;
}

test "bug244: a pointer to a Vec field keeps the field across a whole struct assignment" {
	let b: Bag244 = { tags: [1], n: 0 };
	const tp = b.tags as Ptr<Vec<int32>>;
	b = { tags: [4, 5, 6], n: 1 };
	assert tp[].length == 3;
	assert tp[][1] == 5;
}
