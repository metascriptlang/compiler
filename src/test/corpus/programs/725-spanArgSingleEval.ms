// @stdout: span-arg all-ok
// A Span argument is passed as two C values, (data, len). Both must come from
// ONE evaluation of the source: the reference materializes the argument into a
// location first (openArrayLoc → initLocExpr, ccgcalls.nim) and then repeats
// that location's NAME. Repeating the source EXPRESSION instead handed the
// callee one object's pointer with a different object's length — `vary()` below
// returned a 1-byte buffer on its first call and an 8-byte one on its second,
// and the callee was told it could read 8 bytes of the 1-byte buffer.

let calls = 0;

function vary(): uint8[] {
	calls = calls + 1;
	if (calls == 1) {
		const one: uint8[] = [11];
		return one;
	}
	const many: uint8[] = [22, 22, 22, 22, 22, 22, 22, 22];
	return many;
}

function empty(): uint8[] {
	const none: uint8[] = [];
	return none;
}

function describe(s: Span<uint8>): string {
	return s.length.toString() + ":" + s[0].toString();
}

function lengthOf(s: Span<uint8>): number {
	return s.length;
}

function sum(s: Span<int32>): number {
	let total = 0;
	let i = 0;
	while (i < s.length) {
		total = total + s[i];
		i = i + 1;
	}
	return total;
}

let ok = true;

const shape = describe(vary());
if (shape != "1:11") {
	ok = false;
	console.log("FAIL pair=" + shape + " (data and len came from different evaluations)");
}
if (calls != 1) {
	ok = false;
	console.log("FAIL evaluations=" + calls.toString());
}

// An empty array has no payload allocation, so its data pointer is NULL. The
// length guard has to hand out a null view rather than dereference it.
const emptyLen = lengthOf(empty());
if (emptyLen != 0) {
	ok = false;
	console.log("FAIL emptyLen=" + emptyLen.toString());
}

// A literal at a Span argument: the reference binds it to a fixed-size array and
// passes (buffer, STATIC length) — there is no `len` field to read off it.
const literalSum = sum([4, 5, 6]);
if (literalSum != 15) {
	ok = false;
	console.log("FAIL literalSum=" + literalSum.toString());
}

// The source in an if-CONDITION and in a statement that also holds a ternary:
// the two statement kinds the transform-level materializer (3dafdba) skipped.
// Single-eval there is owned by the analyzer's shared-node capture memo.
calls = 0;
if (describe(vary()) != "1:11") {
	ok = false;
	console.log("FAIL ifcond (data and len came from different evaluations)");
}
if (calls != 1) {
	ok = false;
	console.log("FAIL ifcond evaluations=" + calls.toString());
}

calls = 0;
let flagM = calls == 0;
const mixed = describe(vary()) + (flagM ? "-t" : "-f");
if (mixed != "1:11-t") {
	ok = false;
	console.log("FAIL mixed=" + mixed);
}
if (calls != 1) {
	ok = false;
	console.log("FAIL mixed evaluations=" + calls.toString());
}

// An empty result in if-condition position: the data pointer must come from
// the null guard, not a raw payload deref.
if (lengthOf(empty()) != 0) {
	ok = false;
	console.log("FAIL emptyIfCond");
}

if (ok) {
	console.log("span-arg all-ok");
}
