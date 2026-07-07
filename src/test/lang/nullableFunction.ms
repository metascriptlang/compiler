// Regression tests for Function | null Maybe-wrapping.
// Before fix: Function was not in isMaybeWrappable, so `() => T | null` resolved
// to broken Union<Function, Null> with empty C-struct variants. Every field
// read/write failed with msClosure ↔ msUnion incompatible-type errors.

type Producer = () => number;

function fortyTwo(): number { return 42; }

// Wraps a bare named function into a Producer closure (msClosure form).
// Used because named functions are C function pointers until wrapped.
function wrap(p: Producer): Producer { return p; }

struct BoxStruct {
	fn: Producer | null;
}

interface BoxIface {
	fn: Producer | null;
}

test "struct field: assign non-null closure, read back" {
	const b: BoxStruct = { fn: wrap(fortyTwo) };
	const v = b.fn;
	if (v !== null) {
		const f = v as Producer;
		assert f() === 42;
	} else {
		assert false : "should be non-null";
	}
}

test "struct field: assign null, read back" {
	const b: BoxStruct = { fn: null };
	const v = b.fn;
	assert v === null : "should be null";
}

test "interface field: assign non-null closure, read back" {
	const b: BoxIface = { fn: wrap(fortyTwo) };
	const v = b.fn;
	if (v !== null) {
		const f = v as Producer;
		assert f() === 42;
	} else {
		assert false : "should be non-null";
	}
}

test "interface field: assign null, read back" {
	const b: BoxIface = { fn: null };
	const v = b.fn;
	assert v === null : "should be null";
}
