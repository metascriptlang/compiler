// @ledger-slack(msRefArrayRefCell): 1
// ^ the universal std/meta/node nodeCache module-global survivor — see the
// head of 252-enumDiscUnion for the full attribution.
// note: cross-module union ALIAS through JSON.parse<T> (bug097). The defining
// module's TU emits ShapeTypeInfo citing ShapeDestroy without materializing
// the union struct; ensureDrcProto's name-synthesized proto needed an opaque
// typedef. Proven red pre-fix: `unknown type name 'Shape'` in the shapes TU.
// The decode loop churns the json ref-arrays so the SAN ledger has real
// destroy traffic on this shape.

import { Shape } from "./shapes";

function main(): void {
	const r = JSON.parse<Shape>(`{"kind":"circle","r":2.0}`);
	if (r.ok) {
		console.log("decoded " + r.value.kind);
	} else {
		console.log("failed");
	}

	const bad = JSON.parse<Shape>(`{"kind":"hexagon","z":1}`);
	console.log(bad.ok ? "bad-decoded" : "bad-rejected");

	let n = 0;
	for (let i = 0; i < 200; i = i + 1) {
		const t = JSON.parse<Shape>(`{"kind":"square","side":3.0}`);
		if (t.ok) {
			n = n + 1;
		}
	}
	console.log("loop " + n);
}
main();
