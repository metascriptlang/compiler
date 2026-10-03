// Parked at inbox card 2026-09-27-result-value-union-projection.md

interface WireCircle { kind: "circle"; r: float64; }

interface WireSquare { kind: "square"; side: float64; }

type WireShape = WireCircle | WireSquare;

enum LiteralEventKind { Click, Key }

interface ClickEvent { kind: LiteralEventKind.Click; x: int32; }

interface KeyEvent { kind: LiteralEventKind.Key; code: int32; }

type LiteralEvent = ClickEvent | KeyEvent;

test "serializationVariants: literal-discriminated unions round-trip tag and payload and reject unknown tags" {
	const values: WireShape[] = [{ kind: "circle", r: 2.0 }, { kind: "square", side: 3.0 }];
	for (const value of values) {
		const decoded = JSON.parse<WireShape>(JSON.stringify(value));
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.kind == value.kind;
			if (decoded.value.kind == "circle") assert decoded.value.r == 2.0;
			else assert decoded.value.side == 3.0;
		}
	}
	const direct = JSON.parse<WireShape>(`{"kind":"square","side":3.0}`);
	assert direct.ok;
	if (direct.ok && direct.value.kind == "square") assert direct.value.side == 3.0;
	assert !JSON.parse<WireShape>(`{"kind":"triangle","a":1.0}`).ok;
}

test "serializationVariants: enum-member unions round-trip tag and payload and reject unknown tags" {
	const values: LiteralEvent[] = [{ kind: LiteralEventKind.Click, x: 7 }, { kind: LiteralEventKind.Key, code: 42 }];
	for (const value of values) {
		const decoded = JSON.parse<LiteralEvent>(JSON.stringify(value));
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.kind == value.kind;
			if (decoded.value.kind == LiteralEventKind.Click) assert decoded.value.x == 7;
			else assert decoded.value.code == 42;
		}
	}
	assert !JSON.parse<LiteralEvent>(`{"kind":"Wheel","delta":1}`).ok;
}
