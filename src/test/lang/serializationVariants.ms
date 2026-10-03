interface LiteralCircle { kind: "circle"; r: int32; }

interface LiteralSuccess { ok: true; val: int32; }

enum WireEventKind { Click, KeyPress }

type WireEvent = match (kind: WireEventKind) {
	WireEventKind.Click => { x: int32 },
	WireEventKind.KeyPress => { code: string },
};

interface WireCircle { kind: "circle"; r: float64; }

interface WireSquare { kind: "square"; side: float64; }

type WireShape = WireCircle | WireSquare;

enum LiteralEventKind { Click, Key }

interface ClickEvent { kind: LiteralEventKind.Click; x: int32; }

interface KeyEvent { kind: LiteralEventKind.Key; code: int32; }

type LiteralEvent = ClickEvent | KeyEvent;

struct SequenceFile { path: string; }

function relaySequence<T>(value: T): T { return value; }

function forwardSequence<T>(value: T): T { return relaySequence<T>(value); }

test "serializationVariants: literal discriminant fields serialize as their values rather than carrier tags" {
	const circle: LiteralCircle = { kind: "circle", r: 5 };
	const success: LiteralSuccess = { ok: true, val: 42 };
	assert JSON.stringify(circle) == "{\"kind\":\"circle\",\"r\":5}";
	assert JSON.stringify(success) == "{\"ok\":true,\"val\":42}";
}

test "serializationVariants: match-type union aliases serialize and decode both payload shapes" {
	const values: WireEvent[] = [{ kind: WireEventKind.Click, x: 7 }, { kind: WireEventKind.KeyPress, code: "KC_A" }];
	for (const value of values) {
		const decoded = JSON.parse<WireEvent>(JSON.stringify(value));
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.kind == value.kind;
			if (decoded.value.kind == WireEventKind.Click) assert decoded.value.x == 7;
			else assert decoded.value.code == "KC_A";
		}
	}
	const direct = JSON.parse<WireEvent>(`{"kind":"KeyPress","code":"KC_A"}`);
	assert direct.ok;
	if (direct.ok && direct.value.kind == WireEventKind.KeyPress) assert direct.value.code == "KC_A";
	assert !JSON.parse<WireEvent>(`{"kind":"Drag","x":1}`).ok;
}

test "serializationVariants: literal-discriminated unions round-trip tag and payload and reject unknown tags" {
	const values: WireShape[] = [{ kind: "circle", r: 2.0 }, { kind: "square", side: 3.0 }];
	for (const value of values) {
		const decoded = JSON.parse<WireShape>(JSON.stringify(value));
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.kind == value.kind;
		}
	}
	const direct = JSON.parse<WireShape>(`{"kind":"square","side":3.0}`);
	assert direct.ok;
	assert !JSON.parse<WireShape>(`{"kind":"triangle","a":1.0}`).ok;
	const circle: WireShape = { kind: "circle", r: 2.0 };
	assert JSON.stringify(circle).includes("circle");
}

test "serializationVariants: enum-member unions round-trip tag and payload and reject unknown tags" {
	const values: LiteralEvent[] = [{ kind: LiteralEventKind.Click, x: 7 }, { kind: LiteralEventKind.Key, code: 42 }];
	for (const value of values) {
		const decoded = JSON.parse<LiteralEvent>(JSON.stringify(value));
		assert decoded.ok;
		if (decoded.ok) {
			assert decoded.value.kind == value.kind;
		}
	}
	assert !JSON.parse<LiteralEvent>(`{"kind":"Wheel","delta":1}`).ok;
	const click: LiteralEvent = { kind: LiteralEventKind.Click, x: 7 };
	assert JSON.stringify(click).includes("Click");
}

test "serializationVariants: nested generic forwarding preserves value and reference sequence elements" {
	const files: Vec<SequenceFile> = [{ path: "a" }];
	assert JSON.stringify(files) == `[{"path":"a"}]`;
	const numbers: Vec<float64> = [1, 2];
	const forwarded = forwardSequence(numbers);
	assert forwarded.length == 2 && forwarded[0] == 1 && forwarded[1] == 2;
	const shared: SequenceFile[] = [{ path: "b" }];
	const result = forwardSequence(shared);
	assert JSON.stringify(result) == `[{"path":"b"}]`;
	assert shared[0].path == "b";
}
