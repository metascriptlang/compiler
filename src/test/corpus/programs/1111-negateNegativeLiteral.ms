// Parity program — a negation whose operand is spelled as a negative literal
// builds on C: the operand is parenthesized, so `-` before `-127` is not `--`.
// The 8- and 16-bit minimum is reached, not negated: negating it stops (signedOverflowStops*).
//
// @stdout: 127 32767 127 127 7 -32767
// @stdout: float double 1.5 1.5
// @stdout: float single -1.5 1.5
// @stdout: float separated 1.5 1.5
// @stdout: float expression 2.5 1.5
// @stdout: float indexed 1.5 1.5
// @stdout: float call 1.5 1
// @stdout: float triple -1.5 1.5
// @stdout: float update -1.5 1.5
// @exit: 0

const a: int8 = (-((-127) as int8));
const b: int16 = (-((-32767) as int16));
const m: int8 = (-128) as int8;
const e: int8 = (~((-128) as int8));
const f: int16 = (-(-(7 as int16)));
const z: int16 = -1;
const n: int16 = (-32768) as int16;
console.log(a, b, -(m + 1), e, f, n - z);

function doubleNegation(p: float64): void {
	const result = -(-p);
	console.log("float double", result, p);
}

function singleNegation(p: float64): void {
	const result = -p;
	console.log("float single", result, p);
}

function separatedNegations(p: float64): void {
	const negative = -p;
	const result = -negative;
	console.log("float separated", result, p);
}

function expressionNegation(p: float64): void {
	const result = -(-(p + 1.0));
	console.log("float expression", result, p);
}

function indexedNegation(p: float64): void {
	const values: float64[] = [p];
	const result = -(-values[0]);
	console.log("float indexed", result, values[0]);
}

let calls: int32 = 0;

function nextValue(): float64 {
	calls += 1;
	return 1.5;
}

function callNegation(): void {
	const result = -(-nextValue());
	console.log("float call", result, calls);
}

function tripleNegation(p: float64): void {
	const result = -(-(-p));
	console.log("float triple", result, p);
}

function negatedUpdate(p: float64): void {
	let value = p;
	const result = -(--value);
	console.log("float update", result, value);
}

doubleNegation(1.5);
singleNegation(1.5);
separatedNegations(1.5);
expressionNegation(1.5);
indexedNegation(1.5);
callNegation();
tripleNegation(1.5);
negatedUpdate(2.5);
