// nim-guard: ORC collects a cycle that passes through a nameless object field type
//
// INVARIANT (reference ccgtypes.nim genTypeInfoV2OldImpl: every type-info record carries
//   `traceImpl` from genHook(attachedTrace) next to `destructor`): the TypeInfo of every
//   cell on a cycle names its trace hook, so the collector can walk the whole cycle.
//   Box -> { back: Box | null } -> Box is a cycle whose middle cell has no type name; its
//   TypeInfo is defined by codegen (ensureTypeInfoDef), not by the lifter.
//
// WHAT IT CATCHES: ensureTypeInfoDef wiring destroyFn only (no traceFn / isCyclic) — the
//   collector stops at the nameless cell and both cells leak (Box alloc=N destroy=0).
//
// CONTROL: Named is the same cycle through a named interface; its TypeInfo comes from the
//   lifter, so it collects even without the fix. Only Box red: the codegen-defined TypeInfo
//   lost its trace hook. Both red: ORC itself broke.
//
// DRC is NOT asserted: DRC does not collect cycles by design.
//
// RED MEANS: a TypeInfo defined in codegen lost its trace hook. Run /trace-nim on Box.
// GUARD-BALANCE-ORC Box
// GUARD-BALANCE-ORC Named

interface Box { inner: { back: Box | null; s: string }; }
interface Link { back: Named | null; s: string; }
interface Named { inner: Link; }

function churn(): int32 {
	let i: int32 = 0;
	while (i < 2000) {
		const b: Box = { inner: { back: null, s: "q" } };
		b.inner.back = b;
		const n: Named = { inner: { back: null, s: "r" } };
		n.inner.back = n;
		i = i + 1;
	}
	return i;
}
console.log("done", churn());
