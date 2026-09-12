// Parity program — a match expression joins its arm types even when the
// surrounding context supplies an expected type: an int64 first arm and a
// float64 second arm yield a number, not the first arm's int64.
//
// @stdout: 0.5 0.5 0.5|7 7 7
// @exit: 0

interface V { kind: int32; intVal: int64; floatVal: number; }

function unboxMatch(v: V): number {
	return match (v.kind) {
		0 => v.intVal,
		1 => v.floatVal,
		_ => 0,
	};
}

function unboxIf(v: V): number {
	if (v.kind == 1) return v.floatVal;
	return v.intVal;
}

function unboxMatchFloatFirst(v: V): number {
	return match (v.kind) {
		1 => v.floatVal,
		0 => v.intVal,
		_ => 0,
	};
}

const f: V = { kind: 1, intVal: 0, floatVal: 0.5 };
const i: V = { kind: 0, intVal: 7, floatVal: 0.25 };
console.log(unboxMatch(f) + " " + unboxIf(f) + " " + unboxMatchFloatFirst(f) + "|" + unboxMatch(i) + " " + unboxIf(i) + " " + unboxMatchFloatFirst(i));
