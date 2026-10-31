// Parity program: a union of two numeric kinds that share the "number" tag (int32 and
// int64, int64 and float64, uint64 and float64), alone or nullable, still tells its members
// apart on every backend, through typeof, an exact-kind test, a match, a call and a field.
//
// @stdout: number number object|number number|number number|number number
// @stdout: i32 i64 none|i32 i64|f64 i64|u64 f64
// @stdout: 7 5000000000 1.5 9000000000000000000 5000000000
// @stdout: 11 big
// @exit: 0

struct Holder {
	v: int32 | int64;
}

function pickA(i: int32): int32 | int64 | null {
	if (i == 0) return 7 as int32;
	if (i == 1) return 5000000000 as int64;
	return null;
}
function pickB(i: int32): int32 | int64 {
	if (i == 0) return 7 as int32;
	return 5000000000 as int64;
}
function pickC(i: int32): int64 | float64 {
	if (i == 0) return 9000000000 as int64;
	return 1.5;
}
function pickD(i: int32): uint64 | float64 {
	if (i == 0) return 9000000000000000000 as uint64;
	return 1.5;
}
function label(v: int32 | int64 | null): string {
	if (v == null) return "none";
	return match (typeof v) {
		"int32" => "i32",
		_ => "i64",
	};
}
function labelPair(v: int32 | int64): string {
	return match (typeof v) {
		"int32" => "i32",
		_ => "i64",
	};
}
function labelWide(v: int64 | float64): string {
	return match (typeof v) {
		"int64" => "i64",
		_ => "f64",
	};
}
function labelU(v: uint64 | float64): string {
	return match (typeof v) {
		"uint64" => "u64",
		_ => "f64",
	};
}
function narrowed(v: int32 | int64): string {
	if (typeof v === "int32") {
		const small: int32 = v;
		return `${small + 4}`;
	}
	return "big";
}
function through(h: Holder): string {
	return `${h.v}`;
}

const t1: string[] = [];
for (let i = 0; i < 3; i++) t1.push(typeof pickA(i));
const t2: string[] = [];
for (let i = 0; i < 2; i++) t2.push(typeof pickB(i));
const t3: string[] = [];
for (let i = 0; i < 2; i++) t3.push(typeof pickC(i));
const t4: string[] = [];
for (let i = 0; i < 2; i++) t4.push(typeof pickD(i));
console.log(t1.join(" ") + "|" + t2.join(" ") + "|" + t3.join(" ") + "|" + t4.join(" "));
console.log(
	[label(pickA(0)), label(pickA(1)), label(pickA(2))].join(" ") + "|" +
	[labelPair(pickB(0)), labelPair(pickB(1))].join(" ") + "|" +
	[labelWide(pickC(1)), labelWide(pickC(0))].join(" ") + "|" +
	[labelU(pickD(0)), labelU(pickD(1))].join(" ")
);
const holder: Holder = { v: 5000000000 as int64 };
console.log(`${pickB(0)}`, `${pickB(1)}`, `${pickC(1)}`, `${pickD(0)}`, through(holder));
console.log(narrowed(pickB(0)), narrowed(pickB(1)));
