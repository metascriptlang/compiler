// Test: try operator on Result<T[], E> should unwrap to T[] (msRefArray),
// not void*. Verifies the type flows through result desugaring correctly.

import { compileToC } from "../helpers";

test "try unwraps Result to array type in same module" {
	const src = `
function getNames(): Result<string[], string> {
	const names: string[] = [];
	return Result.ok(names);
}

export function main(): number {
	const names = try getNames() catch [];
	return names.length;
}
`;
	const r = compileToC(src);
	assert r.ok;
	// Should NOT assign void* to array variable
	assert !r.value.contains("= (void*)");
}

test "try unwraps Result with interface array" {
	const src = `
interface Pos {
	line: number;
	column: number;
}

function getPositions(): Result<Pos[], string> {
	const positions: Pos[] = [];
	return Result.ok(positions);
}

export function main(): number {
	const positions = try getPositions() catch [];
	return positions.length;
}
`;
	const r = compileToC(src);
	assert r.ok;
	// The unwrapped value should be an array type, not void*
	assert !r.value.contains("= (void*)");
}
