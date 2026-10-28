// A match used as a value, stored into a declared union alias: each arm is a value of
// that alias, so the sink reads the alias' own struct rather than an anonymous union carrier.

enum MnuKind { Click, Key }

interface MnuClick { kind: MnuKind.Click; x: int32; }

interface MnuKey { kind: MnuKind.Key; code: int32; }

type MnuEvent = MnuClick | MnuKey;

interface MnuCircle { shape: "circle"; r: int32; }

interface MnuSquare { shape: "square"; side: int32; }

type MnuShape = MnuCircle | MnuSquare;

function mnuEvent(a: int32): MnuEvent {
	const v: MnuEvent = match (a) {
		1 => ({ kind: MnuKind.Click, x: a }),
		_ => ({ kind: MnuKind.Key, code: a }),
	};
	return v;
}

function mnuShape(a: int32): MnuShape {
	const outer = a + 1;
	const v: MnuShape = match (outer) {
		2 => ({ shape: "circle", r: a }),
		_ => ({ shape: "square", side: a }),
	};
	return v;
}

function mnuNested(a: int32, b: int32): MnuEvent {
	const v: MnuEvent = match (a) {
		0 => match (b) {
			0 => ({ kind: MnuKind.Click, x: b }),
			_ => ({ kind: MnuKind.Key, code: b }),
		},
		_ => ({ kind: MnuKind.Key, code: a }),
	};
	return v;
}

test "match into a union alias: each arm reads back as its variant" {
	const click = mnuEvent(1);
	assert click.kind == MnuKind.Click;
	const key = mnuEvent(7);
	assert key.kind == MnuKind.Key;
}

test "match into a union alias: a string-discriminant alias keeps its payload" {
	const circle = mnuShape(1);
	assert circle.shape == "circle" && circle.r == 1;
	const square = mnuShape(5);
	assert square.shape == "square" && square.side == 5;
}

test "match into a union alias: a nested match arm stores through the same alias" {
	assert mnuNested(0, 0).kind == MnuKind.Click;
	assert mnuNested(0, 3).kind == MnuKind.Key;
	assert mnuNested(4, 0).kind == MnuKind.Key;
}
