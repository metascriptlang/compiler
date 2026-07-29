// @maxrss: 40
// @stdout: leak-map-drop acc=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED by destructorLifting shouldEmitTypeInfo for mono'd heap classes: a Map<K,V> dropped at scope exit did not free its entries — the mono Map__string_string never ran emitFullTypeInfo (only processDecl does, and a mono has no declaration) so TypeInfo.destroyFn stayed NULL and msDecref skipped the recursive entry free. The mono gate excludes `$`-prefixed synthetic env structs (forcing their TypeInfo in a consumer module breaks the self-host binary compile — they aren't forward-declared there). Nim parity: liftdestructors wires the destructor slot per-instantiation. Was 477MB @ 50k×50 fill+drop, now flat ~2MB drc+orc. Caught by NO inline test or probe; only the full self-host binary build exposed the cross-module compile cascade — this guard pairs with that build as the gate.

// FIXED by destructorLifting shouldEmitTypeInfo for mono'd heap classes: a Map<K,V> instance
// dropped at scope exit did not free its entries. The monomorphized Map__string_string never ran
// emitFullTypeInfo (that runs only from processDecl, and a mono instance has no declaration), so
// TypeInfo.destroyFn stayed NULL and msDecref skipped the recursive entry free — the generated
// Map__string_stringDestroy hook existed but was never wired. Nim parity: liftdestructors wires
// the destructor slot per-instantiation. The mono gate excludes `$`-prefixed synthetic types
// (lambda-lifted env structs) — those are NOT forward-declared in the consumer module that
// first-claims their hooks, so forcing their TypeInfo broke the self-host binary compile.
//
// Permanent regression guard: was 477MB @ 50k×50 fill+drop, now flat ~2MB.

function fillAndDrop(n: number): number {
	const m = new Map<string, string>();
	for (let i = 0; i < n; i = i + 1) {
		m.set("key-" + i, "value-payload-here-longer-string");
	}
	return m.size;
}

function main(): void {
	let acc = 0;
	for (let r = 0; r < 50000; r = r + 1) {
		acc = (acc + fillAndDrop(50)) % 1000;
	}
	console.log(`leak-map-drop acc=${acc}`);
}
main();
