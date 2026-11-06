import { compileToC } from "../helpers";

test "a module const sized array of string literals is a braced initializer" {
	const c = compileToC(`
const FACES: string[3] = ["none", "back", "front"];
console.log(FACES[1]);
`);
	assert c.ok;
	assert c.value.contains("= { { MS_STRING_LIT(&TMP_STR_1, 4), MS_STRING_LIT(");
	assert !c.value.contains(".data[0] = ");
}

test "a module const sized array of string literals has no destroy at exit" {
	const c = compileToC(`
const FACES: string[3] = ["none", "back", "front"];
console.log(FACES[1]);
`);
	assert c.ok;
	assert !c.value.contains("Destroy((&(FACES");
}

test "a module const sized array of int literals is a braced initializer on a native target" {
	const c = compileToC(`
const GRID: int32[4] = [10, 20, 30, 40];
console.log(GRID[2]);
`);
	assert c.ok;
	assert c.value.contains("= { { 10, 20, 30, 40 } };");
	assert !c.value.contains(".data[3] = 40");
}

test "a module let sized array of string literals is still built by init code" {
	const c = compileToC(`
let FACES: string[3] = ["none", "back", "front"];
console.log(FACES[1]);
`);
	assert c.ok;
	assert c.value.contains(".data[0] = ");
}
