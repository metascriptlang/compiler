// bug213 — an extern C function's `T*` / `void*` parameter refused every local but a struct
//
// Symptom:    `import { iter_next } from "g.h"` binds `bool iter_next(Iter, uint16_t* out_y)` as
//             `out_y: Ptr<uint16> | null`; `iter_next(it, y)` with `let y: uint16` failed with
//             "got uint16, expected Ptr<uint16> | null", and so did a `uint16` into `void*`. A `ref`
//             parameter forwarded to such a pointer (or to a `const T*` Borrow) emitted `&(n)`, the
//             address of the pointer itself.
//
// Root cause: the implicit address at an extern argument (NIM-REF CK-102, Nim's `addr`) was granted
//             to struct values only (`promotesToNullablePtr`), and varParamDeref never looked inside
//             a HiddenAddr, so a Var param under one kept its pointer type.
//
// Fix:        `takesAddressAtCArg` (src/checker/compat.ms) admits a scalar, boolean, enum or struct
//             whose type is the pointee, or any of them into `Ptr<void> | null`; relateCallArgs
//             (src/checker/callResolve.ms) grants it at an ImportC argument only and refuses an
//             argument with no address; varParamDeref derefs a Var param inside a HiddenAddr.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
enum Mode { A, B }
struct C { a: int32; }
struct Pair { x: int32; y: uint16; }
class Box { n: int32 = 0; }
extern function fillI32(p: Ptr<int32> | null): int32;
extern function fillU16(p: Ptr<uint16> | null): int32;
extern function fillF64(p: Ptr<number> | null): int32;
extern function fillBool(p: Ptr<boolean> | null): int32;
extern function fillMode(p: Ptr<Mode> | null): int32;
extern function fillI64(p: Ptr<int64> | null): int32;
extern function fillAny(p: Ptr<void> | null): int32;
extern function readI32(p: Borrow<int32>): int32;
function keep(p: Ptr<int32> | null): int32 { return p == null ? 0 : 1; }
function one(): int32 { return 1; }
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { " + body + " }");
	return r.ok ? "" : r.error;
}

test "bug213: a scalar, boolean and enum local pass by address to an extern's Ptr<T> | null" {
	const e = errorsOf("let i: int32 = 0; let u: uint16 = 0; let f: number = 0; let b = false; let m = Mode.A; fillI32(i); fillU16(u); fillF64(f); fillBool(b); fillMode(m); fillI32(null);");
	assert e == "", e;
}

test "bug213: any C value local passes by address to an extern's Ptr<void> | null" {
	const e = errorsOf("let u: uint16 = 0; let m = Mode.B; let c: C = { a: 1 }; fillAny(u); fillAny(m); fillAny(c); fillAny(null);");
	assert e == "", e;
}

test "bug213: a field, an element and a class field have an address" {
	const e = errorsOf("let p: Pair = { x: 0, y: 0 }; const a: int32[] = [0, 0]; const box = new Box(); fillI32(p.x); fillU16(p.y); fillI32(a[1]); fillI32(box.n);");
	assert e == "", e;
}

test "bug213: a literal, a call result and an enum member have no address" {
	assert errorsOf("fillI32(3);").contains("'fillI32' arg 0: expression has no address"), "literal";
	assert errorsOf("fillI32(one());").contains("'fillI32' arg 0: expression has no address"), "call";
	assert errorsOf("fillMode(Mode.A);").contains("in 'fillMode' arg 0: got Mode.A"), "enum member";
}

test "bug213: the pointee is matched exactly, not by widening" {
	const e = errorsOf("let i: int32 = 0; fillI64(i);");
	assert e.contains("Argument type mismatch in 'fillI64' arg 0: got int32, expected Ptr<int64> | null"), e;
}

test "bug213: a MetaScript function and a variable still refuse a scalar" {
	const fnErr = errorsOf("let i: int32 = 0; keep(i);");
	assert fnErr.contains("Argument type mismatch in 'keep' arg 0"), fnErr;
	assert fnErr.contains("only for an extern C function"), fnErr;
	const varErr = errorsOf("let i: int32 = 0; let p: Ptr<int32> | null = i;");
	assert varErr.contains("is not assignable to type 'Ptr<int32> | null'"), varErr;
}

test "bug213: a ref parameter forwards its pointer, not the pointer's address" {
	const c = compileToCWithStd(PRELUDE + "function fwd(ref n: int32): void { fillI32(n); fillAny(n); }");
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) {
		assert c.value.contains("fillI32(&((*n)))"), "Ptr<int32>";
		assert c.value.contains("fillAny(&((*n)))"), "Ptr<void>";
	}
}

test "bug213: a ref parameter forwarded to a Borrow<T> passes its pointer" {
	const c = compileToCWithStd(PRELUDE + "function peek(ref n: int32): int32 { return readI32(n); }");
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("readI32(&((*n)))"), "Borrow<int32>";
}
