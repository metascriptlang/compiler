// An anonymous union, or another alias of the same members, is the same type as a declared union
// alias, so it is accepted wherever the alias is expected. The two have different C carriers, so
// the value is converted into the alias' own carrier at each such place.

enum UacKind { Click, Key }

interface UacClick { kind: UacKind.Click; x: int32; }

interface UacKey { kind: UacKind.Key; code: int32; }

type UacEvent = UacClick | UacKey;

type UacOther = UacClick | UacKey;

interface UacCircle { shape: "circle"; r: int32; }

interface UacSquare { shape: "square"; side: int32; }

type UacShape = UacCircle | UacSquare;

function uacAnon(a: int32): UacClick | UacKey {
	if (a > 0) return { kind: UacKind.Click, x: a };
	return { kind: UacKind.Key, code: a };
}

function uacOther(a: int32): UacOther {
	if (a > 0) return { kind: UacKind.Click, x: a };
	return { kind: UacKind.Key, code: a };
}

function uacShape(a: int32): UacCircle | UacSquare {
	if (a > 0) return { shape: "circle", r: a };
	return { shape: "square", side: a };
}

function uacReturn(a: int32): UacEvent {
	return uacAnon(a);
}

function uacTake(e: UacEvent): int32 {
	return e.kind == UacKind.Click ? 1 : 2;
}

test "union alias carrier: a call result of the anonymous union initializes the alias" {
	const v: UacEvent = uacAnon(1);
	assert v.kind == UacKind.Click;
	const w: UacEvent = uacAnon(-1);
	assert w.kind == UacKind.Key;
}

test "union alias carrier: a function declared to return the alias returns the anonymous union" {
	assert uacReturn(1).kind == UacKind.Click;
	assert uacReturn(-1).kind == UacKind.Key;
}

test "union alias carrier: a parameter typed as the alias receives the anonymous union" {
	assert uacTake(uacAnon(1)) == 1;
	assert uacTake(uacAnon(-1)) == 2;
}

test "union alias carrier: an alias array takes the anonymous union by push" {
	const xs: UacEvent[] = [];
	xs.push(uacAnon(1));
	xs.push(uacAnon(-1));
	assert xs.length == 2 && xs[0].kind == UacKind.Click && xs[1].kind == UacKind.Key;
}

test "union alias carrier: a second alias of the same members is accepted by the first" {
	const v: UacEvent = uacOther(-1);
	assert v.kind == UacKind.Key;
}

test "union alias carrier: a string-discriminant alias keeps its payload through the conversion" {
	const v: UacShape = uacShape(4);
	assert v.shape == "circle" && v.r == 4;
	const w: UacShape = uacShape(-2);
	assert w.shape == "square" && w.side == -2;
}
