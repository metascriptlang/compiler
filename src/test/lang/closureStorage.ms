class Slot {
	cb: () => void;
	hasCb: boolean;
	constructor() {
		this.cb = () => {};
		this.hasCb = false;
	}
	set(c: () => void): void {
		this.cb = c;
		this.hasCb = true;
	}
}

type StoredHandler = (text: string) => void;

type StoredOperation = (value: int32) => int32;

type StoredCompare = (left: int32, right: int32) => int32;

function dispatchEvent(event: string, callback: (name: string, payload: string) => void): void { callback(event, "data"); }

function takeCb(cb: () => string): string {
	return cb();
}

function iterationClosures(): (() => int32)[] {
	const out: (() => int32)[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		const value = i;
		out.push(() => value);
	}
	return out;
}

type CallableExpressionAdder = (n: int32) => int32;

interface CallableExpressionHolder {
	fn: CallableExpressionAdder;
}

function callableExpressionMakeAdder(k: int32): CallableExpressionAdder {
	return (n: int32): int32 => n + k;
}

function callableExpressionPickAdder(useFirst: boolean, a: CallableExpressionAdder, b: CallableExpressionAdder): CallableExpressionAdder {
	if (useFirst) return a;
	return b;
}

function* callableExpressionGen(): Iterator<int32> {
	yield 1;
	yield 2;
	yield 3;
}

test "closureStorage: closure captures let inside test block (single)" {

	let captured: string[] = [];
	const s = new Slot();
	s.set(() => {
		captured = ["a", "b"];
	});
	const fn = s.cb;
	fn();
	assert captured.length == 2;
	assert captured[0] == "a" && captured[1] == "b";
}

test "closureStorage: closure captures let inside test block (mutating counter)" {
	let counter: int32 = 0;
	const s = new Slot();
	s.set(() => {
		counter = counter + 1;
	});
	const fn = s.cb;
	fn();
	fn();
	fn();
	assert counter == 3;
}

test "closureStorage: map closure storage retains signature and captured state across lookup" {
	let seen = "";
	const handlers = new Map<string, StoredHandler>();
	handlers.set("append", (text) => { seen = seen + text; });
	assert handlers.has("append") && !handlers.has("missing");
	const append = handlers.get("append")!;
	append("a");
	append("b");
	assert seen == "ab";
	const operations = new Map<string, StoredOperation>();
	operations.set("double", (value) => value * 2);
	operations.set("increment", (value) => value + 1);
	assert operations.size == 2;
	const twice = operations.get("double")!;
	const increment = operations.get("increment")!;
	assert twice(3) == 6;
	assert increment(3) == 4;
	const compares = new Map<string, StoredCompare>();
	compares.set("min", (left, right) => left < right ? left : right);
	compares.set("max", (left, right) => left > right ? left : right);
	const minimum = compares.get("min")!;
	const maximum = compares.get("max")!;
	for (const value of [2, 7]) {
		assert minimum(3, value) == (value < 3 ? value : 3);
		assert maximum(3, value) == (value > 3 ? value : 3);
	}
}

test "closureStorage: void callbacks preserve early return and fallthrough effects" {
	let seen = "";
	for (const name of ["skip", "accept"]) {
		dispatchEvent(name, (event, payload) => {
			if (event == "skip") return;
			seen = seen + payload;
		});
	}
	assert seen == "data";
	let hits: int32 = 0;
	dispatchEvent("only-return", (event, payload) => { hits++; return; });
	assert hits == 1;
}

test "closureStorage: inferred function expressions retain their callable signature" {
	const myFn = function(): string {
		return "fn-expr";
	};
	const got = myFn();
	assert got == "fn-expr";
}

test "closureStorage: const = () => T can be called (no annotation)" {
	const myFn = () => "arrow";
	const got = myFn();
	assert got == "arrow";
}

test "closureStorage: const arrow with multiple params" {
	const add = (a: int32, b: int32): int32 => (a + b) as int32;
	assert add(3, 4) == 7;
}

test "closureStorage: const arrow capturing outer let" {
	let counter: int32 = 0;
	const bump = () => { counter = counter + 1; };
	bump();
	bump();
	bump();
	assert counter == 3;
}

test "closureStorage: LHS-annotated const arrow still works" {
	const myFn: () => string = () => "lhs";
	assert myFn() == "lhs";
}

test "closureStorage: arrow as callback arg still works" {
	assert takeCb(() => "callback") == "callback";
}

test "closureStorage: escaped closure arrays retain their iteration values over repeated scope exits" {
	for (let round: int32 = 0; round < 50; round++) {
		const closures = iterationClosures();
		assert closures.length == 3;
		for (let i: int32 = 0; i < 3; i++) assert closures[i]() == i;
	}
}

test "closureStorage: a closure returned by a call is callable in place" {
	assert callableExpressionMakeAdder(1)(2) == 3;
}

test "closureStorage: a closure selected by a ternary is callable in place" {
	const flag = true;
	assert (flag ? callableExpressionMakeAdder(100) : callableExpressionMakeAdder(200))(5) == 105;
}

test "closureStorage: a closure read out of an array is callable in place" {
	const table: CallableExpressionAdder[] = [callableExpressionMakeAdder(1000), callableExpressionMakeAdder(2000)];
	assert table[0](7) == 1007;
	assert table[1](7) == 2007;
}

test "closureStorage: a closure held in a field is callable in place" {
	const holder: CallableExpressionHolder = { fn: callableExpressionMakeAdder(30000) };
	assert holder.fn(7) == 30007;
}

test "closureStorage: a closure relayed through a parameter is callable in place" {
	assert callableExpressionPickAdder(true, callableExpressionMakeAdder(3), callableExpressionMakeAdder(4))(1) == 4;
	assert callableExpressionPickAdder(false, callableExpressionMakeAdder(3), callableExpressionMakeAdder(4))(1) == 5;
}

test "closureStorage: a for-of generator still steps through its iterator" {

	let total: int32 = 0;
	for (const v of callableExpressionGen()) {
		total = total + v;
	}
	assert total == 6;
}
