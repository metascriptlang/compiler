// @maxrss: 30
// @stdout: generic-ext-protocol PASS
// note: Cross-module convention protocol through a generic (the yoga layoutPass<T> shape): generic in module A calls extension methods on T defined only in the instantiating module B. instantiateGenericFunction re-checks the cloned body via pickBodyCtx (defining module's ctx) whose per-module extensionRegistry lacked B's extensions → member call unresolved → raw generic emitted with T=void* → C compile error; the unresolved call's unknown return also cascaded the recursion into walkTree<unknown>. Fix: inject the instantiating ctx's extensions into the body-check registry for the re-check duration, then truncate (Nim mixin semantics; mirrors injectConcreteTypeSyms/removeInjectedSyms in the same function). Two instantiations (Panel, Widget) assert per-type dispatch.

// Cross-module convention protocol through a generic (the yoga layoutPass
// shape): a generic function defined in one module calls extension methods
// on T that only exist in the INSTANTIATING module — Nim `mixin` semantics,
// docs/PROTOCOLS.md Part II.
//
// Contract: protocol extensions MUST be exported. The instance is emitted in
// the defining module's TU, so it calls the extensions cross-TU; private
// extensions are not injected and produce a check-time "no member" error
// with an "in instantiation of" note (see protocols.ms compileProjectToC
// tests for both negative cases).

import { walkTree } from "./genericExtProtocolLib";

interface Panel { name: string; children: Panel[]; depth: float32; }
interface Widget { id: string; kids: Widget[]; level: float32; }

export function protoKids(this p: Panel): Panel[] { return p.children; }
export function protoBump(this p: Panel, v: float32): void { p.depth = v; }
export function protoKids(this w: Widget): Widget[] { return w.kids; }
export function protoBump(this w: Widget, v: float32): void { w.level = v * 10.0; }

function main(): void {
	const p: Panel = { name: "root", children: [{ name: "a", children: [], depth: 0.0 }], depth: 0.0 };
	const w: Widget = { id: "root", kids: [{ id: "b", kids: [], level: 0.0 }], level: 0.0 };
	walkTree(p, 1.0);
	walkTree(w, 1.0);
	let ok = true;
	if (!(p.depth === 1.0 && p.children[0].depth === 2.0)) { ok = false; }
	if (!(w.level === 10.0 && w.kids[0].level === 20.0)) { ok = false; }
	if (ok) {
		console.log("generic-ext-protocol PASS");
	} else {
		console.log("generic-ext-protocol FAIL p=" + p.depth.toString() + "," + p.children[0].depth.toString()
			+ " w=" + w.level.toString() + "," + w.kids[0].level.toString());
	}
}

main();
