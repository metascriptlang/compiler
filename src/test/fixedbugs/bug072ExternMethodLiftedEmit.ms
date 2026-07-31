// bug072 — a MemberExpr named like a static extern method must not emit the extern's body
//
// Symptom:    An interface field named `log` (or a closure-captured local
//             `log`, which lambda lifting turns into an env FIELD access)
//             made the std/core/system TU emit a definition
//             `static void log(msRefArray*)` — colliding with libm's
//             `extern double log(double)` → C build failure.
//
// Root cause: reachability.ms MemberExpr fallback (no resolvedSym on field
//             accesses) marks methods alive BY NAME → class console alive.
//             methodToFunction lifts `static extern log(...) from "msPrintln"`
//             into a top-level FunctionDecl carrying fnFlags="extern" +
//             nativeName — but genFunctionDecl's isExternFn keyed ONLY on
//             sym.ImportC and the lifted node has no resolvedSym, so the
//             extern got a generated body with its unmangled name.
//
// Fix:        declarations.ms — isExternFn/hasNativeName also read the node's
//             own fnFlags/nativeName; same extern guard mirrored into
//             genMethodAsFunction (defensive, normally unreached post-lift).

interface Rec {
	log: string;
}

test "bug072: interface field named log compiles and reads" {
	const r: Rec = { log: "field" };
	assert r.log === "field";
}

test "bug072: closure capturing a local named log compiles and runs" {
	let log = "a";
	const w = (): string => log;
	log = log + "b";
	assert w() === "ab";
}
