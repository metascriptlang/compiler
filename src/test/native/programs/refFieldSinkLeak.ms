// Guards the value-type =sink leak for Ref-typed fields. A struct (or tuple) holding a
// post-migration `Ref<Array>` (or interface/class) field, reassigned in a loop, leaked the
// PRIOR field value on every sink: refOp's sink arm raw-assigned `dest.field = src.field`
// without decref'ing the old ref — the one sink variant that violated the =sink-owns-old
// convention that stringOp and arrayOp already honor (Nim atomicRefOp attachedSink: decref
// dest, then assign). The cyclic write-barrier ordering Nim uses under gcOrc is unnecessary
// here because our ORC defers collection (runtime/drc.h), so decref-first is safe drc+orc.
// Was 119MB @ 50k (struct) / 135MB (tuple-of-array), now ~2.3MB drc+orc; ASAN clean.
// Only the native binary runs the C =sink hook.

struct Holder { arr: string[]; tag: int32; }

function mk(seed: number): string[] {
	let s = "x";
	for (let i = 0; i < 10; i = i + 1) { s = s + s; }
	const a: string[] = [];
	a.push(s);
	a.push(s);
	return a;
}

function main(): void {
	let h: Holder = { arr: mk(0), tag: 0 as int32 };
	let acc = 0;
	for (let i = 0; i < 80000; i = i + 1) {
		h = { arr: mk(i), tag: i as int32 };
		acc = (acc + h.tag) % 1000;
	}
	console.log(`ref-field-sink done acc=${acc}`);
}
main();
