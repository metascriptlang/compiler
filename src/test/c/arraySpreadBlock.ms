// A spread of an array into an array literal sizes the result once and copies a source of
// hook-free elements as one block, as a sequence copy does; an element that needs its copy
// hook keeps the element loop inside the same reserved capacity.

import { compileToC } from "../helpers";

test "a number array spread reserves once and block-copies with no per-element push" {
	const c = compileToC(`
function main(): void {
	const nums: number[] = [1, 2, 3];
	const copy: number[] = [...nums];
	console.log(copy.length);
}
`);
	assert c.ok;
	assert c.value.contains("msGenericArrayReserveMore(");
	assert c.value.contains("msGenericArrayAppendBlock(");
	assert !c.value.contains("msGenericArrayPush(dollarspra");
}

test "plain elements after a spread are counted in its reservation and still pushed" {
	const c = compileToC(`
function main(): void {
	const a: int32[] = [1, 2];
	const joined: int32[] = [...a, 3, 4];
	console.log(joined.length);
}
`);
	assert c.ok;
	assert c.value.contains("msGenericArrayAppendBlock(");
	assert c.value.contains(".len, 2)");
}

test "a string array spread reserves once and keeps the copying element loop" {
	const c = compileToC(`
function main(): void {
	const words: string[] = ["a", "b"];
	const copy: string[] = [...words];
	console.log(copy.length);
}
`);
	assert c.ok;
	assert c.value.contains("msGenericArrayReserveMore(");
	assert !c.value.contains("msGenericArrayAppendBlock(");
	assert c.value.contains("msStringCopy(");
}
