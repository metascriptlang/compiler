// bug488 — ORC never collected a cycle that passes through an object type with no name
//
// Symptom:    `interface Box { inner: { back: Box | null; s: string } }` with `b.inner.back = b`
//             leaked both cells under --gc=orc (Box 1/0, msAnon 1/0); a named twin collected.
// Root cause: codegen defines the TypeInfo of a type the lifter reached only through a field,
//             and it wired the destructor but not the trace hook, so the collector could not
//             walk from the nameless cell back to Box.
// Fix:        ensureTypeInfoDef wires traceFn and isCyclic from the type's attached trace hook,
//             as every TypeInfo record carries its trace hook next to its destructor.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function traceWired(c: string): boolean {
	let at = c.indexOf("msAnon_", 0);
	while (at >= 0) {
		const eol = c.indexOf("\n", at);
		const line = c.slice(at, eol > 0 ? eol : c.byteLength);
		if (line.contains("TypeInfo.traceFn = (msTraceProc)msAnon_")) return true;
		at = c.indexOf("msAnon_", at + 1);
	}
	return false;
}

test "bug488: a nameless field type on a cycle gets its trace hook in TypeInfo" {
	const c = cOf("export interface Box { inner: { back: Box | null; s: string }; }\nexport function mk(): Box { const b: Box = { inner: { back: null, s: \"q\" } }; b.inner.back = b; return b; }\n");
	assert traceWired(c);
	assert c.contains("TypeInfo.isCyclic = MS_TRUE;");
}

test "bug488: the same wiring one nameless level deeper" {
	const c = cOf("export class Box { inner: { mid: { back: Box | null; w: int32 } } = { mid: { back: null, w: 1 } }; }\nexport function mk(): Box { const b = new Box(); b.inner.mid.back = b; return b; }\n");
	assert traceWired(c);
}
