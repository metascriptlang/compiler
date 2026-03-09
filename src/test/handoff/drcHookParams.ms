// DRC Hook Param Convention — verify lifecycle hooks use pointer params (Nim: var T)
//
// Root cause: destructorLifting creates hooks with value-typed params,
// but inject.ms always wraps args in HiddenAddr (pointer). The forward decls
// in declarations.ms use pointer. The body must match.

import { compileToC } from "../helpers";

function contains(haystack: string, needle: string): boolean {
	return haystack.indexOf(needle) >= 0;
}

test "DRC hooks use pointer params for small interface" {
	const source = "interface SmallThing {\n\tname: string;\n}\nfunction makeIt(): SmallThing {\n\treturn { name: \"hello\" };\n}\nconst x = makeIt();\n";
	const result = compileToC(source);
	if (!result.ok) {
		console.log("ERROR: " + result.error);
		assert false;
	}
	const c = result.value;
	// Find the destroy signature
	const idx = c.indexOf("SmallThing_destroy(");
	if (idx >= 0) {
		console.log("FOUND: " + c.slice(idx, idx + 60));
	} else {
		console.log("NOT FOUND: SmallThing_destroy");
		// Show last 500 chars to see what's there
		const tail = c.length > 500 ? c.slice(c.length - 500, c.length) : c;
		console.log("TAIL: " + tail);
	}
	// _destroy should take pointer: SmallThing* self, not SmallThing self
	assert contains(c, "SmallThing_destroy(SmallThing* self)") || contains(c, "SmallThing_destroy(SmallThing *self)");
}

test "DRC hooks use pointer params for copy" {
	const source = "interface SmallThing {\n\tname: string;\n}\nfunction makeIt(): SmallThing {\n\treturn { name: \"hello\" };\n}\nlet x = makeIt();\nlet y = x;\n";
	const result = compileToC(source);
	assert result.ok;
	const c = result.value;
	// _copy should take pointers: SmallThing* dest, SmallThing* src
	assert contains(c, "SmallThing_copy(SmallThing* dest, SmallThing* src)") || contains(c, "SmallThing_copy(SmallThing *dest, SmallThing *src)");
}

test "DRC hooks use pointer params for wasMoved" {
	const source = "interface SmallThing {\n\tname: string;\n}\nfunction consume(t: SmallThing): void {}\nconst x: SmallThing = { name: \"hello\" };\nconsume(move x);\n";
	const result = compileToC(source);
	assert result.ok;
	const c = result.value;
	// _wasMoved should take pointer
	assert contains(c, "SmallThing_wasMoved(SmallThing* self)") || contains(c, "SmallThing_wasMoved(SmallThing *self)");
}
