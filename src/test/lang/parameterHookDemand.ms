struct DemandPayload { text: string; count: int32; }
struct DemandBox<T> { value: T; }
interface DemandRef { text: string; }

function demandHeap(text: string): string { return text + "!"; }
function demandRead(p: DemandPayload): string { return p.text; }
function demandChange(ref p: DemandPayload): void { p.text = p.text + "r"; }
function demandFill(out p: DemandPayload): void { p = { text: demandHeap("out"), count: 2 }; }
function demandReadonly(readonly p: DemandPayload): string {
	let copy = p;
	copy.text = copy.text + "i";
	return copy.text;
}
function demandTuple(p: [string, int32]): [string, int32] { return p; }
function demandSized(p: string[2]): string[2] { return p; }
function demandGeneric<T>(p: DemandBox<T>): T { return p.value; }
function demandRef(p: DemandRef): DemandRef { return p; }
function demandPtr(p: Ptr<DemandPayload>): string { return p.text; }
function demandBorrow(p: Borrow<DemandPayload>): string { return p.text; }
function demandCursor(p: Cursor<DemandPayload>): string { return p.text; }
function demandReadonlyPtr(p: Readonly<Ptr<DemandPayload>>): string { return p.text; }
function demandBorrowRef(p: Borrow<DemandRef>): string { return p.text; }
function demandCollect<T>(p: T): T[] { const values: T[] = []; values.push(p); return values; }

test "parameter demand: value and readonly views preserve the caller payload" {
	const p: DemandPayload = { text: demandHeap("value"), count: 1 };
	assert demandRead(p) == "value!";
	assert demandReadonly(p) == "value!i";
	assert p.text == "value!";
}

test "parameter demand: ref and out payloads survive replacement" {
	let p: DemandPayload = { text: demandHeap("value"), count: 1 };
	demandChange(p);
	assert p.text == "value!r";
	demandFill(p);
	assert p.text == "out!";
	assert p.count == 2;
}

test "parameter demand: tuple formal copies keep owned elements alive" {
	const p: [string, int32] = [demandHeap("tuple"), 7];
	let copied = demandTuple(p);
	copied[0] = demandHeap("new");
	assert p[0] == "tuple!";
	assert copied[0] == "new!";
	assert copied[1] == 7;
}

test "parameter demand: sized array formal copies isolate replacement" {
	const p: string[2] = [demandHeap("left"), demandHeap("right")];
	let copied = demandSized(p);
	copied[0] = demandHeap("new");
	assert p[0] == "left!";
	assert copied[0] == "new!";
	assert copied[1] == "right!";
}

test "parameter demand: a generic value payload retains managed fields" {
	const p: DemandBox<DemandPayload> = { value: { text: demandHeap("generic"), count: 9 } };
	let copied = demandGeneric(p);
	copied.text = demandHeap("new");
	assert p.value.text == "generic!";
	assert copied.text == "new!";
	assert copied.count == 9;
}

test "parameter demand: reference payloads keep shared identity" {
	const p: DemandRef = { text: demandHeap("ref") };
	const copied = demandRef(p);
	copied.text = demandHeap("new");
	assert p.text == "new!";
}

test "parameter demand: pointer borrowed cursor and readonly pointer formals read live payloads" {
	let p: DemandPayload = { text: demandHeap("borrow"), count: 3 };
	assert demandPtr(p as Ptr<DemandPayload>) == "borrow!";
	assert demandBorrow(p as Borrow<DemandPayload>) == "borrow!";
	assert demandCursor(p as Cursor<DemandPayload>) == "borrow!";
	assert demandReadonlyPtr(p as Ptr<DemandPayload>) == "borrow!";
	assert p.text == "borrow!";
}

test "parameter demand: borrowed reference formals read the owned pointee" {
	const p: DemandRef = { text: demandHeap("borrow-ref") };
	assert demandBorrowRef(p as Borrow<DemandRef>) == "borrow-ref!";
	assert p.text == "borrow-ref!";
}

test "parameter demand: sized array values survive a generic sink into dynamic storage" {
	const p: string[2] = [demandHeap("left"), demandHeap("right")];
	const values = demandCollect<string[2]>(p);
	assert values[0][0] == "left!";
	assert values[0][1] == "right!";
	assert p[0] == "left!";
}
