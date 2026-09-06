// bug044 — nullable-ref struct field dropped by generated copy/destroy hook
//
// Symptom:    A value `struct` with a `Ref<T> | null` field silently lost that
//             field whenever the struct was copied (e.g. HashMap.get / array
//             read-back) — the field read back null. First surfaced via
//             SpawnSlotEntry.innerType in awaitLower: `const h = spawn(fn);
//             await h` emitted no unbox (void* → double compile error) because
//             the stored inner Type was dropped. C + --gc=drc/orc only; JS and
//             gc=none copy the struct whole so they were unaffected.
// Root cause: destructorLifting.ms fillBody TypeKind.Union arm had no case for
//             an anonymous nullable-ref union (Ref<T>|null / Ptr<T>|null), so
//             the field was omitted from Copy/Destroy/WasMoved — while
//             classify.ms treats the same shape as a managed Ref
//             (unwrapRefNullUnion). The two paths disagreed.
// Fix:        fillBody Union arm unwraps the nullable-ref union → refOp
//             (incref/decref), mirroring classify.ms; Ptr/actor inner → plain
//             copy. Keeps the TS `T | null` union model, matches Nim tyRef DRC.

interface Bug044Ty { kind: number; }
struct Bug044Entry { a: number; t: Bug044Ty | null; }

test "bug044: nullable-ref struct field survives HashMap round-trip" {
	const m = new HashMap<string, Bug044Entry>();
	const ty: Bug044Ty = { kind: 6 };
	m.set("k", { a: 1, t: ty });
	const g = m.get("k");
	assert g != null;
	if (g != null) {
		assert g.t != null;
		if (g.t != null) assert g.t.kind == 6;
	}
}

test "bug044: nullable-ref struct field survives array round-trip" {
	const ty: Bug044Ty = { kind: 7 };
	const arr: Bug044Entry[] = [{ a: 2, t: ty }];
	const g = arr[0];
	assert g.t != null;
	if (g.t != null) assert g.t.kind == 7;
}
