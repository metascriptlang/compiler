const WideConstantWIDE: uint64 = 18446744073709551615;

const WideConstantTHIRD: uint64 = WideConstantWIDE / 3;

const WideConstantLOWEST: int32 = -2147483648;

const WideConstantNEGATIVE: int64 = -9223372036854775807;

const WideConstantFOUR_GB: int64 = 1024 * 1024 * 1024 * 4;

function wideConstantScaled(k: int64): int64 {
	return 100000 * 100000 * k;
}

function wideConstantReturned(): int64 {
	return 100000 * 100000;
}

struct WideLoopHolder { epoch: uint64; }

function wideLoopAdvancedTo(this holder: WideLoopHolder, epoch: uint64): WideLoopHolder {
	return { epoch: holder.epoch + epoch };
}

const FloatConstantSTEP: float32 = 0.42;

const FloatConstantBIG: float32 = 16777217.0;

const FloatConstantONE: float32 = 1.0;

const FloatConstantWIDE: float64 = FloatConstantSTEP;

let floatConstantStep: float32 = 0.42;

let floatConstantBig: float32 = 16777217.0;

function floatConstantTimes(a: float32, b: float32): float32 {
	return a * b;
}

test "numericRepresentation: 0.0 / 0.0 produces NaN, not panic" {
	const nan: number = 0.0 / 0.0;
	assert nan != nan;  
}

test "numericRepresentation: 1.0 / 0.0 produces +Infinity" {
	const posInf: number = 1.0 / 0.0;
	assert posInf > 1e308;
}

test "numericRepresentation: -1.0 / 0.0 produces -Infinity" {
	const negInf: number = -1.0 / 0.0;
	assert negInf < -1e308;
}

test "numericRepresentation: float division with integer-valued operands preserves precision" {
	const quotient: number = 2.0 / 3.0;
	assert quotient > 0.66 && quotient < 0.67;
}

test "numericRepresentation: float text uses shortest round-trip digits across decimal and exponent boundaries" {
	const values: float64[] = [3.14, 0.1, -3.14, 1.0 / 3.0, 100.0, 0.0, 1e21, 1e20, 0.000001, 1e-7];
	const texts: string[] = ["3.14", "0.1", "-3.14", "0.3333333333333333", "100", "0", "1e+21", "100000000000000000000", "0.000001", "1e-7"];
	for (let i: int32 = 0; i < values.length; i++) assert `${values[i]}` == texts[i], "float text at " + i.toString();
}

test "numericRepresentation: hex literal with e is an integer" {
	const a = 0xe0 | 1;
	assert a == 225;
	const b = 0xE0 | 1;
	assert b == 225;
	const c = 0xbeef & 0xffff;
	assert c == 48879;
	const d: int32 = 0xffee;
	assert d == 65518;
	assert 0xe0 == 224;
	assert 0xE1 == 225;
}

test "numericRepresentation: uint64 division keeps all bits" {
	assert WideConstantTHIRD == 6148914691236517205;
}

test "numericRepresentation: signed boundary literals keep their value" {
	assert WideConstantLOWEST + 1 == -2147483647;
	assert WideConstantNEGATIVE + 9223372036854775807 == 0;
}

test "numericRepresentation: an integer constant expression folds exactly into its int64 slot" {
	const big: int64 = 100000 * 100000;
	const year: int64 = 60 * 60 * 24 * 365 * 1000;
	assert big == 10000000000;
	assert year == 31536000000;
	assert WideConstantFOUR_GB == 4294967296;
	assert wideConstantScaled(1) == 10000000000;
	assert wideConstantReturned() == 10000000000;
}

test "numericRepresentation: an integer constant past int32 takes int64 without a slot, beside a narrower operand and in a float slot" {
	const unslotted = 100000 * 100000;
	const lone = 4000000000;
	const narrow: int32 = 2;
	const wider = narrow * (100000 * 100000);
	const real: float64 = 100000 * 100000;
	assert unslotted == 10000000000;
	assert lone + 1 == 4000000001;
	assert wider == 20000000000;
	assert real == 10000000000.0;
}

test "numericRepresentation: a bitwise integer constant keeps its int32 value in an int64 slot" {
	const shifted: int64 = 1 << 31;
	const expected: int64 = -2147483648;
	assert shifted == expected;
}

test "numericRepresentation: uint64 counter crosses 2^31" {
	let last: uint64 = 0;
	for (let big: uint64 = 2147483646; big < 2147483650; big++) {
		last = big;
	}
	assert last == 2147483649;
}

test "numericRepresentation: int64 counter crosses 2^31" {
	let steps: int32 = 0;
	let last: int64 = 0;
	for (let wide: int64 = 2147483645; wide <= 2147483650; wide++) {
		last = wide;
		steps++;
	}
	assert last == 2147483650;
	assert steps == 6;
}

test "numericRepresentation: uint64 counter reaches a method-syntax uint64 formal" {
	let holder: WideLoopHolder = { epoch: 0 };
	for (let epoch: uint64 = 1; epoch <= 3; epoch++) {
		holder = holder.wideLoopAdvancedTo(epoch);
	}
	assert holder.epoch == 6;
}

test "numericRepresentation: a float32 const multiplies as a float32" {
	for (let n = 0; n < 64; n++) {
		const x = n as float32;
		assert x * FloatConstantSTEP == floatConstantTimes(x, floatConstantStep);
	}
}

test "numericRepresentation: a float32 const chain rounds like the runtime" {
	const sum: float32 = floatConstantBig + FloatConstantONE;
	assert FloatConstantBIG + FloatConstantONE == sum;
}

test "numericRepresentation: a float32 const widened to float64 keeps its float32 value" {
	const wide: float64 = floatConstantStep;
	assert FloatConstantWIDE == wide;
	assert FloatConstantWIDE * 3.0 == wide * 3.0;
}

interface SinkNumbers { wide: int64; small: int32; byte: uint8; }

test "numericRepresentation: sink arguments convert numeric payloads before native collection storage" {
	const source: SinkNumbers = { wide: 1, small: 2, byte: 3 };
	const numbers: number[] = [];
	numbers.push(source.wide);
	numbers.push(source.small);
	numbers.push(source.byte);
	const doubles: float64[] = [];
	doubles.push(source.wide);
	const labels: string[] = ["zero", "one", "two", "three", "four"];
	assert labels[numbers[0]] == "one";
	assert numbers[1] + numbers[2] == 5;
	assert doubles[0] + 0.5 == 1.5;
	const map = new Map<string, number>();
	const other: SinkNumbers = { wide: 4, small: 2, byte: 3 };
	map.set("key", other.wide);
	assert labels[map.get("key")!] == "four";
}
