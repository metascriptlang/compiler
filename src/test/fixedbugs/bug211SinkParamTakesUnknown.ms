// bug211 — a sink parameter of type unknown refused an unknown argument
//
// Symptom:    `items.push(make())` with `items: unknown[]` and `make(): unknown` failed with
//             `unknown is not assignable to <kind:Sink>`; the HCR host fixture stopped building.
// Root cause: the unknown-argument checks in `relateCallArgs` read the parameter type with its
//             `sink` layer still on, so `Sink<unknown>` was not recognised as unknown.
// Fix:        both checks read the parameter through `skipModifier`, like the assignability check.

import { compileToC } from "../helpers";

const header = `
extern function opaque(): unknown from "NULL";
extern function keep(sink v: unknown): void from "keep";
extern function keepInt(sink v: int32): void from "keepInt";
function make(): unknown { return opaque(); }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug211: an unknown value pushes into an array of unknown" {
	assert errorOf("const items: unknown[] = [];\nitems.push(make());\n") == "";
}

test "bug211: an unknown value passes a sink unknown parameter" {
	assert errorOf("keep(make());\n") == "";
}

test "bug211: an unknown value still needs a cast for a sink int32 parameter" {
	assert errorOf("keepInt(make());\n").indexOf("unknown is not assignable to int32") >= 0;
}
