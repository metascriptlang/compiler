let compoundG: int32 = 3;

function compoundSetG(): int32 {
	compoundG = 100;
	return 1;
}

let compoundW: uint64 = 10 as uint64;

function compoundSetW(): uint64 {
	compoundW = 100 as uint64;
	return 1 as uint64;
}

let compoundS16: uint16 = 3;

function compoundDec16(): uint16 {
	compoundS16--;
	return 2;
}

class CompoundBox {
	v: int32 = 3;
}

const compoundBox = new CompoundBox();

function compoundSetBox(): int32 {
	compoundBox.v = 100;
	return 2;
}

const compoundArr: int32[] = [3, 3];

function compoundSetArr(): int32 {
	compoundArr[1] = 100;
	return 2;
}

function compoundGlobals(): string {
	compoundG = 3;
	compoundG *= compoundSetG();
	const mul = compoundG;
	compoundG = 10;
	compoundG -= compoundSetG();
	compoundW = 10 as uint64;
	compoundW -= (false ? compoundW : compoundSetW());
	compoundS16 = 3;
	compoundS16 *= compoundDec16();
	return `${mul} ${compoundG} ${compoundW} ${compoundS16}`;
}

function compoundCaptured(): string {
	let n: int32 = 3;
	const w = (): int32 => {
		n = 100;
		return 2;
	};
	n *= w();
	let x: float64 = 3;
	const wx = (): float64 => {
		x = 100;
		return 2;
	};
	x += wx();
	return `${n} ${x}`;
}

function compoundPlaces(): string {
	compoundBox.v = 3;
	compoundBox.v *= compoundSetBox();
	compoundArr[1] = 3;
	compoundArr[1] += compoundSetArr();
	let k: int32 = 5;
	k += k++;
	return `${compoundBox.v} ${compoundArr[1]} ${k}`;
}

function compoundLoopUpdate(): string {
	let i: int32 = 0;
	let steps: int32 = 0;
	const step = (): int32 => {
		i = i + 100;
		return 1;
	};
	for (let t = 0; i < 3; i += step()) steps += 1;
	return `${steps} ${i}`;
}

function compoundInsideClosure(): string {
	let s: int32 = 1;
	let t: float64 = 1;
	const bump = (k: int32): int32 => k + 1;
	const run = (cb: () => void): void => { cb(); };
	run((): void => {
		s += bump(2);
		t *= bump(3) as float64;
		run((): void => { s += bump(s); });
	});
	return `${s} ${t}`;
}

function compoundRaiseKeepsTarget(): string {
	let bits: number = 6;
	let n: int32 = 3;
	let captured: int32 = 4;
	const raise = (): int32 => { throw new Error("neg"); };
	try { bits &= raise(); } catch (e) { }
	try { n *= raise(); } catch (e) { }
	const inner = (): void => {
		try { captured += raise(); } catch (e) { }
	};
	inner();
	return `${bits} ${n} ${captured}`;
}

let compoundBits: number = 6;

function compoundSetBits(): number {
	compoundBits = 100;
	return 3;
}

function compoundBitwiseNumber(): string {
	compoundBits = 6;
	compoundBits &= compoundSetBits();
	const a = compoundBits;
	compoundBits = 6;
	compoundBits |= compoundSetBits();
	const o = compoundBits;
	compoundBits = 6;
	compoundBits ^= compoundSetBits();
	const x = compoundBits;
	compoundBits = 6;
	compoundBits <<= compoundSetBits();
	const l = compoundBits;
	compoundBits = 6;
	compoundBits >>= compoundSetBits();
	const r = compoundBits;
	compoundBits = -6;
	compoundBits >>>= compoundSetBits();
	return `${a} ${o} ${x} ${l} ${r} ${compoundBits}`;
}

test "compoundAssignmentEvaluation: a global target is read before a right side that writes it" {
	assert compoundGlobals() == "3 9 9 6";
}

test "compoundAssignmentEvaluation: a captured local is read before a closure on the right writes it" {
	assert compoundCaptured() == "6 5";
}

test "compoundAssignmentEvaluation: a field, an element and a post-increment read their old value" {
	assert compoundPlaces() == "6 5 10";
}

test "compoundAssignmentEvaluation: a loop update reads its counter before the step writes it" {
	assert compoundLoopUpdate() == "3 3";
}

test "compoundAssignmentEvaluation: a target captured by a closure is compounded inside that closure" {
	assert compoundInsideClosure() == "9 4";
}

test "compoundAssignmentEvaluation: a raise on the right keeps a number, an int and a closure target" {
	assert compoundRaiseKeepsTarget() == "6 3 4";
}

test "compoundAssignmentEvaluation: a bitwise compound on a number reads the target before a right side that writes it" {
	assert compoundBitwiseNumber() == "2 7 5 48 0 536870911";
}
