// Test: Enum explicit values are preserved through codegen
//
// Verifies that enum members with explicit values (bitflags, gaps)
// emit the correct integer values in C, not ordinals.

import { compileToC } from "../helpers";

test "enum with sequential values emits correct defines" {
	const result = compileToC("export enum Color { Red, Green, Blue }");
	assert result.ok;
	const code = result.value;
	assert code.contains("#define Color_Red (((Color)0))");
	assert code.contains("#define Color_Green (((Color)1))");
	assert code.contains("#define Color_Blue (((Color)2))");
}

test "enum with explicit bitflag values emits correct defines" {
	const result = compileToC("export enum Flag { None = 0, A = 1, B = 2, C = 4, D = 8, E = 16 }");
	assert result.ok;
	const code = result.value;
	assert code.contains("#define Flag_None (((Flag)0))");
	assert code.contains("#define Flag_A (((Flag)1))");
	assert code.contains("#define Flag_B (((Flag)2))");
	assert code.contains("#define Flag_C (((Flag)4))");
	assert code.contains("#define Flag_D (((Flag)8))");
	assert code.contains("#define Flag_E (((Flag)16))");
}

test "enum with gaps emits correct defines" {
	const result = compileToC("export enum Level { Low = 10, Medium = 50, High = 100 }");
	assert result.ok;
	const code = result.value;
	assert code.contains("#define Level_Low (((Level)10))");
	assert code.contains("#define Level_Medium (((Level)50))");
	assert code.contains("#define Level_High (((Level)100))");
}
