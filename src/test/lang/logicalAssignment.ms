class Slot { n: int32 | null = null; flag: boolean = false; label: string | null = null; count: int32 = 0; }
class Nest { inner: Slot = new Slot(); }

let reached = 0;
let rhsRuns = 0;
const shared = new Slot();
const nest = new Nest();
function slot(): Slot { reached += 1; return shared; }
function inner(): Slot { reached += 1; return nest.inner; }
function rhs(): int32 { rhsRuns += 1; return 7; }

test "logicalAssignment: ??= writes a null place once and leaves a present one alone" {
	let a: int32 | null = null;
	a ??= 3;
	assert a == 3;
	a ??= 9;
	assert a == 3;
}

test "logicalAssignment: ||= writes a falsy place and &&= a truthy one" {
	let zero: int32 = 0;
	zero ||= 5;
	zero ||= 8;
	assert zero == 5;
	let keep: int32 = 4;
	keep &&= 6;
	assert keep == 6;
	let none: int32 = 0;
	none &&= 6;
	assert none == 0;
}

test "logicalAssignment: a boolean and a string place follow their own falsiness" {
	let flag = false;
	flag ||= true;
	assert flag;
	flag &&= false;
	assert !flag;
	let text = "";
	text ||= "filled";
	text &&= "kept";
	assert text == "kept";
	let maybe: string | null = null;
	maybe ??= "set";
	maybe ??= "again";
	assert maybe == "set";
}

test "logicalAssignment: the object of a field place runs once and the right side only when the test passes" {
	reached = 0;
	rhsRuns = 0;
	slot().n ??= rhs();
	assert reached == 1 && rhsRuns == 1;
	slot().n ??= rhs();
	assert reached == 2 && rhsRuns == 1;
	assert shared.n == 7;
}

test "logicalAssignment: the right side stays unrun when ||= meets a truthy place and &&= a falsy one" {
	rhsRuns = 0;
	reached = 0;
	shared.count = 2;
	slot().count ||= rhs();
	shared.count = 0;
	slot().count &&= rhs();
	assert rhsRuns == 0 && reached == 2;
	assert shared.count == 0;
}

test "logicalAssignment: a nested field path runs its call once" {
	reached = 0;
	inner().label ??= "first";
	inner().label ??= "second";
	assert reached == 2;
	assert nest.inner.label == "first";
}

test "logicalAssignment: the index of an element place runs once" {
	const xs: int32[] = [0, 1];
	let calls = 0;
	const at = (): int32 => { calls += 1; return 0; };
	xs[at()] ||= 11;
	xs[at()] ||= 22;
	assert xs[0] == 11 && xs[1] == 1 && calls == 2;
}

test "logicalAssignment: a reference place holds no null afterwards" {
	let held: Slot | null = null;
	held ??= new Slot();
	held.count = 3;
	assert held.count == 3;
}

function orDefault(p: int32): int32 {
	p ||= 42;
	return p;
}

test "logicalAssignment: a parameter written by ||= keeps the new value for its reads" {
	assert orDefault(0) == 42 && orDefault(5) == 5;
}
