// Symptom: checking a generic call whose parameters reach a class with several fields of its own type did not finish: the compiler's own check hung once `Symbol` gained one more `Symbol | null` field.
// Root cause: the scan for a type parameter's constraint walked every path through the parameter types, 20 levels deep, so its cost grew as the number of self-references to the power of the depth.
// Fix: the scan visits each type once and does not enter a declared struct that has no type parameters, the rule type substitution already follows.
import { compileToCWithStd } from "../helpers";

function web615(fieldCount: int32): string {
	let fields = "";
	for (let i: int32 = 0; i < fieldCount; i += 1) fields += `\tf${i}: Web615 | null = null;\n`;
	return `class Web615 {\n${fields}}\nfunction visit615<T>(web: Web615, tag: T): T { return tag; }\nexport const tag615: int32 = visit615(new Web615(), 7);\n`;
}

test "bug615: a generic call over a class with many self-references checks" {
	const result = compileToCWithStd(web615(32));
	assert result.ok, result.ok ? "" : result.error;
}
