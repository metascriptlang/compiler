// @maxrss: 30
// @stdout: static-storage PASS
// note: `static const`/`static let` — a declaration written inside a body whose storage lives at module scope. Runtime proof that the unit guard (fixedbugs/bug102) cannot give: if the slot were a frame local the initializer would re-run and `once1()` would return A1/A2/A3; if the analyzer still queued module-scope storage for scope-exit destroy (the missing sfGlobal arm of the reference's per-declaration destroy routing, fixed 2026-08-10) the RC-typed slot would be freed after the first call and the second read would be a use-after-free. The RC type is load-bearing — an int-typed slot needs no cleanup and passes even when the routing is wrong. `builds` counts initializer runs: 1 for the `static const` plus 2 for the two `static let` calls, on every lane. Also pins that two functions declaring the SAME source name (`t`) get distinct module-scope slots — the reference mangles a proc-level global by unique symbol id, MS by declaration site. Parity C↔JS is the point: both backends implement the split independently.

let builds: int32 = 0;

function mk(tag: string): string {
	builds = builds + 1;
	return tag + builds.toString();
}

// Storage at module scope, initializer run once.
function once1(): string { static const t = mk("A"); return t; }

// Same storage class, `let` spelling: keeps the reference's per-call init.
function perCall(): string { static let t = mk("B"); return t; }

// Two sites, same source name, different functions.
function a(): int32 { static const t = 1; return t; }
function b(): int32 { static const t = 2; return t; }

function main(): void {
	let ok = true;

	if (once1() != "A1") ok = false;
	if (once1() != "A1") ok = false;
	if (once1() != "A1") ok = false;

	if (perCall() != "B2") ok = false;
	if (perCall() != "B3") ok = false;

	if (a() != 1) ok = false;
	if (b() != 2) ok = false;
	if (a() != 1) ok = false;

	if (builds != 3) ok = false;

	if (ok) {
		console.log("static-storage PASS");
	} else {
		console.log("static-storage FAIL builds=" + builds.toString());
	}
}

main();
