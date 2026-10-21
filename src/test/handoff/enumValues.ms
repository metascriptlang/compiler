// Test: Enum explicit values are preserved through codegen
//
// Verifies that enum members with explicit values (bitflags, gaps)
// emit the correct integer values in C, not ordinals.

import { compileToC } from "../helpers";

// The value of `#define <E>__<mod>_<member> (((<E>__<mod>)<value>))`, or "".
function defineValue(code: string, enumName: string, member: string): string {
	for (const line of code.split("\n")) {
		if (line.startsWith("#define " + enumName + "__") && line.contains("_" + member + " (((" + enumName + "__")) {
			return line.slice(line.lastIndexOf(")", line.length - 3) + 1, line.length - 2);
		}
	}
	return "";
}

test "enum with sequential values emits correct defines" {
	const result = compileToC("export enum Color { Red, Green, Blue }");
	assert result.ok;
	const code = result.value;
	assert defineValue(code, "Color", "Red") == "0";
	assert defineValue(code, "Color", "Green") == "1";
	assert defineValue(code, "Color", "Blue") == "2";
}

test "enum with explicit bitflag values emits correct defines" {
	const result = compileToC("export enum Flag { None = 0, A = 1, B = 2, C = 4, D = 8, E = 16 }");
	assert result.ok;
	const code = result.value;
	assert defineValue(code, "Flag", "None") == "0";
	assert defineValue(code, "Flag", "A") == "1";
	assert defineValue(code, "Flag", "B") == "2";
	assert defineValue(code, "Flag", "C") == "4";
	assert defineValue(code, "Flag", "D") == "8";
	assert defineValue(code, "Flag", "E") == "16";
}

test "enum with gaps emits correct defines" {
	const result = compileToC("export enum Level { Low = 10, Medium = 50, High = 100 }");
	assert result.ok;
	const code = result.value;
	assert defineValue(code, "Level", "Low") == "10";
	assert defineValue(code, "Level", "Medium") == "50";
	assert defineValue(code, "Level", "High") == "100";
}
