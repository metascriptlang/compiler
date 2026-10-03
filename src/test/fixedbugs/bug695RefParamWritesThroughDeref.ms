// Symptom: writing through `q[]` with `ref q: Ptr<T>` (`q[].v = 11`, `q[] = …`) was refused at check ("operand is out Ptr<T>, a value"); reading through it worked.
// Root cause: the checker typed a var parameter as its pointee only on reads; on an assignment target it kept `Var<T>`, so every operand under the target (`x[]`, `x[i]`, `x.f`) saw the pointer flavour and each consumer had to special-case it; the reference dereferences a var expression wherever it is used, read or write.
// Fix: a var parameter is typed as its pointee on every use, and the C transform materialises its dereference under any other one.

struct Cell695 { v: int32; }

function setField(ref q: Ptr<Cell695>): void { q[].v = 11; }
function setWhole(ref q: Ptr<Cell695>, x: int32): void { q[] = { v: x }; }
function bumpField(ref q: Ptr<Cell695>): void { q[].v = q[].v + 1; }
function retarget(ref q: Ptr<Cell695>, other: Ptr<Cell695>): void { q = other; }

test "bug695: writes through q[] on a ref Ptr parameter" {
	let c: Cell695 = { v: 2 };
	let p: Ptr<Cell695> = c as Ptr<Cell695>;
	setField(p);
	assert c.v == 11;
	setWhole(p, 30);
	assert c.v == 30;
	bumpField(p);
	assert c.v == 31;
}

test "bug695: reassigning a ref Ptr parameter retargets the caller's pointer" {
	let a: Cell695 = { v: 1 };
	let b: Cell695 = { v: 2 };
	let p: Ptr<Cell695> = a as Ptr<Cell695>;
	retarget(p, b as Ptr<Cell695>);
	assert p[].v == 2;
}
