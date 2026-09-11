import { compileToC } from "../helpers";

const PRELUDE = `
enum Flag { A, B, C }
enum Kind { X, Y }
enum Mask { P = 1, Q = 2 }
enum Other { R = 4, S = 8 }
type Meters = distinct int32;
type Feet = distinct int32;
function opaqueI32(x: int32): int32 { return x; }
`;

function compiles(body: string): boolean {
	return compileToC(PRELUDE + body).ok;
}

test "a healthy program still compiles" {
	assert compiles("const n: int32 = opaqueI32(1);");
}

test "int32 does not flow into a BitSet slot" {
	assert !compiles("const f: BitSet<Flag> = opaqueI32(1);");
}

test "an enum member does not flow into a BitSet slot" {
	assert !compiles("const f: BitSet<Flag> = Flag.A;");
}

test "a mixed-enum union does not flow into a BitSet slot" {
	assert !compiles("const f: BitSet<Flag> = Flag.A | Kind.X;");
}

test "int32 does not flow into a distinct slot" {
	assert !compiles("const m: Meters = opaqueI32(1);");
}

test "a distinct does not flow into its base slot" {
	assert !compiles("function f(m: Meters): void { const n: int32 = m; }");
}

test "a distinct does not flow into a sibling distinct slot" {
	assert !compiles("function f(m: Meters): void { const n: Feet = m; }");
}

test "an enum value does not flow into another enum's slot" {
	assert !compiles("function f(k: Kind): void { const e: Flag = k; }");
}

test "an explicit distinct cast flows into a distinct slot" {
	assert compiles("const m: Meters = 5 as Meters;");
}

test "an enum value flows into an int32 slot" {
	assert compiles("function f(k: Kind): void { const n: int32 = k; }");
}

test "members of different ordinal enums do not combine" {
	assert !compiles("const n = Flag.A | Kind.X;");
	assert !compiles("const n = Flag.A & Kind.X;");
	assert !compiles("const n = Flag.A ^ Kind.X;");
}

test "an ordinal enum member does not combine with another enum's hand-numbered member" {
	assert !compiles("const n = Flag.A | Mask.P;");
}

test "members of the same ordinal enum combine" {
	assert compiles("const n = Flag.A | Flag.B;");
}

test "an ordinal enum member combines with an integer" {
	assert compiles("const n = Flag.A | 4;");
	assert compiles("const n = Flag.B << 2;");
}

test "hand-numbered members keep the integer rule across enums" {
	assert compiles("const n = Mask.P | Other.R;");
	assert compiles("const n = Mask.P | Mask.Q;");
}
