// nim-guard: Vec<T> (value seq) and T[] (ref array) are distinct containers
//
// INVARIANT (Nim sigmatch typeRel: tySequence and tyRef are different kinds,
//   no implicit relation either way — `seq` ↔ `ref` conversion is always
//   explicit): MS `Vec<T>` = bare Array (value seq), `T[]`/`Array<T>` =
//   Ref(Array) (resolvePass.ms representation tests). Implicit cross-use in
//   EITHER direction must be a checker error: the Ref auto-deref arm
//   (compat.ms, built for self-referential field promotion) must not peel
//   Ref(Array) into a bare-Array slot, and fitNode's memory-safety class
//   (isReinterpretUnsafe, NIM-REF row 80) must reject the container-kind
//   mismatch at every fit site.
//
// WHAT IT CATCHES: re-widening the auto-deref arm or dropping the
//   isReinterpretUnsafe pair lets Vec↔T[] cross-assign through the checker
//   again — pre-fix that emitted invalid C (clang "assigning to
//   'int32_tArray' from incompatible type", a toolchain error leaking to the
//   user) while JS silently ran, and T[]→Vec param calls rode a coincidental
//   ABI pun (box pointer happens to match the by-pointer value-aggregate
//   convention). Probed 2026-08-28: x1/x2 clang-die + JS-run, x4 runs on
//   both — all three now checker errors.
//
// RED MEANS: the container-kind blur is back — either a clang error leaks to
//   users or value/ref semantics silently fork per backend. Run /trace-nim
//   against sigmatch typeRel tySequence/tyRef.
//
// GUARD-CHECK-FAIL Type 'Vec<int32>' is not assignable to type 'int32[]'
// GUARD-CHECK-FAIL Type 'int32[]' is not assignable to type 'Vec<int32>'
// GUARD-CHECK-FAIL got int32[], expected Array

function takeVec(v: Vec<int32>): int32 { return v.length; }

function vecToRefAssign(): void {
	const v: Vec<int32> = [1, 2];
	const r: int32[] = v;
	console.log("" + r.length);
}

function refToVecAssign(): void {
	const r: int32[] = [1, 2];
	const v: Vec<int32> = r;
	console.log("" + v.length);
}

function refToVecParam(): void {
	const r: int32[] = [1, 2, 3];
	console.log("" + takeVec(r));
}

vecToRefAssign();
refToVecAssign();
refToVecParam();
