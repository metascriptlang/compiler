// bug576 — a constrained generic alias instance kept its type parameter unsubstituted
//
// Symptom:    `type Box<T extends number> = { value: T }; const b: Box<int32> = { value: 42 };`
//             printed `<T>` on C: the instance body still carried the parameter.
// Root cause: generic params are recorded with their constraint (`T:number`), and the body
//             substitution used that whole string as the parameter name.
// Fix:        genericParamNames strips the constraint before any substitution.

import { compileToC } from "../helpers";

test "bug576: a constrained alias instance lays out its argument type" {
	const c = compileToC("type Box<T extends number> = { value: T };\nconst b: Box<int32> = { value: 42 };\nconsole.log(b.value);");
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("int32_t value");
	}
}
