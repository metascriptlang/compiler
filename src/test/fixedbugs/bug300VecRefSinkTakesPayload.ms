// bug300 — a Vec of class references was sunk with the copy hook
//
// Symptom:    `let v: Vec<Item> = mk(); v = mk();` leaked every element of both vectors
//             (DRC ledger `Item alloc=5 destroy=2`): the new payload was copied with an
//             incref per element, the call result was zeroed without a destroy, and the
//             old elements were never released.
// Root cause: `classifyArray` gave reference-element value arrays `msArrayRefCopy` as
//             their sink hook, and the `msArrayRefSink` macro freed the old payload
//             without releasing its elements.
// Fix:        the sink slot names `msArrayRefSink`, which destroys the old elements when
//             the payloads differ and then takes the source payload, as Nim's seq `=sink`.

import { compileToC } from "../helpers";

function emitted(src: string): string {
	const c = compileToC(src);
	return c.ok ? c.value : `compile failed: ${c.error}`;
}

test "bug300: reassigning a Vec of class references sinks the call result" {
	const out = emitted(`
		class Item { n: int32 = 0; }
		function mk(): Vec<Item> { const v: Vec<Item> = [new Item()]; return v; }
		function run(): void {
			let v: Vec<Item> = mk();
			v = mk();
			console.log(v.length);
		}
		run();
	`);
	assert out.contains("msArrayRefSink(v_1_");
	assert !out.contains("msArrayRefCopy(v_1_");
}

test "bug300: reassigning a Vec of nullable class references sinks the call result" {
	const out = emitted(`
		class Item { n: int32 = 0; }
		function mk(): Vec<Item | null> { const v: Vec<Item | null> = [new Item(), null]; return v; }
		function run(): void {
			let w: Vec<Item | null> = mk();
			w = mk();
			console.log(w.length);
		}
		run();
	`);
	assert out.contains("msArrayRefSink(w_1_");
	assert !out.contains("msArrayRefCopy(w_1_");
}
