// Route 15: .toString() resolution on primitives and enums
//
// number.toString(), enum.toString() must resolve a symbol so
// codegen can emit the correct C function call.

import { checkSource } from "./helpers";
import { hasErrors } from "../../checker/context";

test "number.toString() resolves without error" {
	const src = "const x: number = 42;\nconst s: string = x.toString();";
	const ctx = checkSource(src);
	assert ctx != null;
	// Should not have unresolved member access
	assert !hasErrors(ctx);
}

test "enum.toString() resolves without error" {
	const src = "enum Color { Red, Green, Blue }\nconst c = Color.Red;\nconst s: string = c.toString();";
	const ctx = checkSource(src);
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "boolean.toString() resolves without error" {
	const src = "const b = true;\nconst s: string = b.toString();";
	const ctx = checkSource(src);
	assert ctx != null;
	assert !hasErrors(ctx);
}
