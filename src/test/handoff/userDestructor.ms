// Route: user-authored lifecycle hooks (=destroy parity).
//
// A method/extension named `onDestroy` on a type must be wired into the
// generated <T>Destroy. Two prior bugs broke this end-to-end:
//   1. gating — a handle-only type (no RC fields) emitted no destructor at all,
//      so the hook was never reached (typeNeedsHooks ignored user hooks).
//   2. retrieval — the hook was looked up by reconstructing `typeName+"onDestroy"`,
//      which never matched the real (mangled) symbol → call dropped.
// A user hook OVERRIDES the field traversal (reference parity) — the author owns
// all fields, so the auto field-walk is skipped when a hook is present.

import { compileToC } from "../helpers";

function countSub(hay: string, needle: string): number {
	let n = 0;
	let i = hay.indexOf(needle);
	while (i >= 0) {
		n = n + 1;
		i = hay.indexOf(needle, i + needle.length);
	}
	return n;
}

// The body of the `<T>__<mod>Destroy` definition, from its signature line to its closing brace; "" when absent.
function destroyBody(code: string, typeName: string): string {
	const lines = code.split("\n");
	let i = 0;
	while (i < lines.length && !(lines[i].startsWith("void " + typeName + "__") && lines[i].contains("Destroy(" + typeName + "__") && lines[i].endsWith(" {"))) i = i + 1;
	if (i == lines.length) return "";
	let body = "";
	while (i < lines.length && lines[i] != "}") { body = body + lines[i] + "\n"; i = i + 1; }
	return body;
}

test "user onDestroy on a handle-only class is wired into the destructor" {
	const src = "class Res { h: int64; onDestroy(): void { this.h = 0; } }\n"
		+ "function use(): void { const a: Res = { h: 1 }; a.h = 2; }\n"
		+ "use();";
	const c = compileToC(src);
	assert c.ok;
	// Gating: a handle-only class would emit only minimal TypeInfo (no destructor)
	// without the fix — the destructor existing proves the user hook forced it.
	assert destroyBody(c.value, "Res") != "";
	// Wiring: decl + def + call (3×). Without the call it would be 2×.
	assert countSub(c.value, "Res_onDestroy") >= 3;
}

test "user onDestroy OVERRIDES the field walk (replace, not augment)" {
	const src = "class Aug { name: string; h: int64; onDestroy(): void { this.h = 0; } }\n"
		+ "function use(): void { const a: Aug = { name: \"x\", h: 1 }; a.h = 2; }\n"
		+ "use();";
	const c = compileToC(src);
	assert c.ok;
	// Isolate the destructor body (def-brace → next function) and assert the hook
	// is called but the owned `name` string is NOT auto-freed — the author owns it.
	const body = destroyBody(c.value, "Aug");
	assert body.contains("Aug_onDestroy");
	assert body.indexOf("msStringDecref") < 0;
}

test "extension-method onDestroy is wired (registry retrieval, not name guess)" {
	const src = "interface Ext { h: int64; name: string }\n"
		+ "function onDestroy(this self: Ext): void { self.h = 0; }\n"
		+ "function use(): void { const a: Ext = { h: 1, name: \"y\" }; a.h = 2; }\n"
		+ "use();";
	const c = compileToC(src);
	assert c.ok;
	assert destroyBody(c.value, "Ext").contains("onDestroy");
	assert countSub(c.value, "onDestroy") >= 3;
}

function petHookSource(receiver: string): string {
	return "struct Pet { hunger: uint16; name: string; }\n"
		+ "function onDestroy(" + receiver + "): void {\n"
		+ "console.log(\"destroy \" + self.name);\n"
		+ "}\n"
		+ "function use(): void { let a: Pet = { hunger: 1, name: \"y\" }; a.hunger = 2; }\n"
		+ "use();";
}

test "user onDestroy on a Var<T> receiver is wired to T like one on a this ref receiver" {
	const byRef = compileToC(petHookSource("this ref self: Pet"));
	assert byRef.ok, byRef.error;
	assert countSub(byRef.value, "onDestroy") >= 3;
	const byVar = compileToC(petHookSource("this self: Var<Pet>"));
	assert byVar.ok, byVar.error;
	assert byVar.value == byRef.value;
}
