// Symptom: `==` between fixed arrays of different lengths or element types, or between a fixed array and an array, passed the checker; C then failed at clang and JS compared by reference.
// Root cause: the checker's equality rule accepted any two pointer-like operands, and a fixed array counted as one.
// Fix: a fixed array compares only with the same fixed-array type, as Nim's `==`[I, T](x, y: array[I, T]) takes both operands of one array type (comparisons.nim:309).
import { compileToJS } from "../helpers";

function checkError(decls: string): string {
	const r = compileToJS(`${decls}\nconsole.log(a == b);\n`);
	return r.ok ? "" : r.error;
}

test "bug630: fixed arrays of different lengths or element types are not comparable" {
	const lengths = checkError("const a: uint8[4] = [1, 2, 3, 4];\nconst b: uint8[3] = [1, 2, 3];");
	const elements = checkError(
		"const a: uint8[4] = [1, 2, 3, 4];\nconst b: uint16[4] = [1, 2, 3, 4];",
	);
	const array = checkError("const a: uint8[4] = [1, 2, 3, 4];\nconst b: uint8[] = [1, 2, 3, 4];");
	assert lengths.indexOf("operator '==' cannot be applied", 0) >= 0, lengths;
	assert elements.indexOf("operator '==' cannot be applied", 0) >= 0, elements;
	assert array.indexOf("operator '==' cannot be applied", 0) >= 0, array;
}

test "bug630: fixed arrays of one type are comparable" {
	const same = checkError("const a: uint8[4] = [1, 2, 3, 4];\nconst b: uint8[4] = [1, 2, 3, 5];");
	assert same == "", same;
}
