// bug071 — element-narrow arrays (uint8[]/int32[]) widened onto number[] externs
//
// Symptom:    every number[] method a narrow array lacked bound the number[]
//             extern (8-byte stride) against a 1/4-byte payload:
//             u8.indexOf(20) === -1, u8.pop() === 1e-323, u8.join garbage,
//             u8.fill heap-overflow crash, [10,20,30].indexOf(20) === -1
//             (unannotated literal infers int32[]). Silent wrong answers on C.
//
// Root cause: isReceiverMatch (checker/context.ms) compared array receivers by
//             ELEMENT isAssignable — covariant — while Nim keeps seq elements
//             invariant (sigmatch.nim:1502-1516) and MS's own isAssignable
//             already rejects uint8[]→number[] at the container level
//             (compat.ms sameElementRepr, NIM-REF row 74). The receiver site
//             bypassed the central relation.
//
// Fix:        isReceiverMatch consults isReinterpretUnsafe on the unwrapped
//             containers before element assignability, so repr-mismatched
//             receivers never bind; narrow arrays fall to the generic T[]
//             surface (index.cms), whose msGenericArray* macros carry
//             sizeof(data[0]) — Nim's prepareSeqAddUninit(sizeof(T)) shape.
//             msGenericArrayPush/SetLen cap checks gained the bug067 flag
//             mask so borrowed views divert to msArrayPrepareAdd's copy.

test "bug071: uint8[] indexOf/includes/count via generic surface" {
	const b: uint8[] = [];
	b.push(10);
	b.push(20);
	b.push(30);
	assert b.indexOf(20) === 1;
	assert b.indexOf(99) === -1;
	assert b.includes(30);
	assert !b.includes(99);
	assert b.count(20) === 1;
}

test "bug071: uint8[] pop and shift return real bytes" {
	const b: uint8[] = [];
	b.push(10);
	b.push(20);
	b.push(30);
	assert b.pop() === 30;
	assert b.shift() === 10;
	assert b.length === 1;
	assert b[0] === 20;
}

test "bug071: uint8[] slice copies at byte stride" {
	const b: uint8[] = [1, 2, 3, 4];
	const s = b.slice(1, 3);
	assert s.length === 2;
	assert s[0] === 2;
	assert s[1] === 3;
}

test "bug071: uint8[] fill and reverse in place" {
	const b: uint8[] = [1, 2, 3];
	b.fill(9);
	assert b[0] === 9;
	assert b[2] === 9;
	const c: uint8[] = [1, 2, 3];
	c.reverse();
	assert c[0] === 3;
	assert c[2] === 1;
}

test "bug071: uint8[] concat builds a fresh byte array" {
	const a: uint8[] = [1, 2];
	const b: uint8[] = [3];
	const out = a.concat(b);
	assert out.length === 3;
	assert out[0] === 1;
	assert out[2] === 3;
	assert a.length === 2;
}

test "bug071: unannotated int literal array (int32[]) indexOf" {
	const n = [10, 20, 30];
	assert n.indexOf(20) === 1;
	const i32: int32[] = [10, 20, 30];
	assert i32.indexOf(20) === 1;
	assert i32.includes(30);
}

test "bug071: asBytes view reads through the generic surface" {
	const v = "abc".asBytes();
	assert v.indexOf(98) === 1;
	const s = v.slice(1, 3);
	assert s.length === 2;
	assert s[0] === 98;
}

test "bug071: number[] and string[] keep their extern fast paths" {
	const nums: number[] = [10.5, 20.5];
	assert nums.indexOf(20.5) === 1;
	assert nums.includes(10.5);
	const strs: string[] = ["a", "b"];
	assert strs.indexOf("b") === 1;
}
