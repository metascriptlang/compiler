// Checker — a generator's next() passes no value in and its return carries none, so reading the
// value of `yield` or `yield*` is refused; a `yield` written as a statement stays legal.

import { strictErrorCount, hasError } from "./helpers";

test "reading the value of yield is refused in a generator with a declared Iterator type" {
	assert hasError("function* g(): Iterator<int32> { const got = yield 1; yield 2; }", "the value of 'yield' cannot be read");
	assert hasError("function* g(): Iterator<int32> { const s: string = yield 1; }", "the value of 'yield' cannot be read");
}

test "reading the value of yield is refused in a generator without a declared type" {
	assert hasError("function* g() { console.log(yield 1); }", "the value of 'yield' cannot be read");
}

test "reading the value of yield* is refused" {
	assert hasError("function* g(): Iterator<int32> { yield 1; }\nfunction* k(): Iterator<int32> { const r = yield* g(); }", "the value of 'yield*' cannot be read");
}

test "a yield whose value is discarded is accepted as a statement and as a for update" {
	assert strictErrorCount("function* g(): Iterator<int32> { yield 1; for (let i: int32 = 2; i < 4; yield i) i++; yield* [7, 8]; }") == 0;
	assert strictErrorCount("function* g() { yield 5; }") == 0;
}
