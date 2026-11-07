import { compileToC, compileProjectToC } from "../helpers";

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

test "a module const string array of literals is a flagged static payload" {
	const c = compileToC(`
const NAMES: string[] = ["alpha", "beta", "gamma"];
console.log(NAMES[1]);
`);
	assert c.ok;
	assert c.value.contains("_data_ = { MS_STRLIT_FLAG | 3, { MS_STRING_LIT(");
	assert !c.value.contains("msStringArrayFromArr(");
	assert !c.value.contains("msArrayPayloadNew(");
}

test "a module const int array of literals is a flagged static payload" {
	const c = compileToC(`
const NUMS: int32[] = [1, 2, 3, 4];
console.log(NUMS[1]);
`);
	assert c.ok;
	assert c.value.contains("_data_ = { MS_STRLIT_FLAG | 4, { 1, 2, 3, 4 } };");
	assert !c.value.contains("msArrayPayloadNew(");
}

test "a module const array with a non-literal element is still built by init code" {
	const c = compileToC(`
function f(): string { return "x"; }
const NAMES: string[] = ["alpha", f()];
console.log(NAMES[1]);
`);
	assert c.ok;
	assert !c.value.contains("MS_STRLIT_FLAG | 2");
}

test "a module const array of sized-array literals is a flagged static payload with nested braces" {
	const c = compileToC(`
type Limb = uint32[3];
const ROWS: Limb[] = [[1, 2, 3], [4, 5, 6]];
console.log(ROWS[1][2]);
`);
	assert c.ok;
	assert c.value.contains("_data_ = { MS_STRLIT_FLAG | 2, { { { 1U, 2U, 3U } }, { { 4U, 5U, 6U } } } };");
	assert !c.value.contains("msArrayPayloadNew(");
}

test "a module const array of struct literals is a flagged static payload" {
	const c = compileToC(`
struct Pair { a: int32; b: int32; }
const PAIRS: Pair[] = [{ a: 1, b: 2 }, { a: 3, b: 4 }];
console.log(PAIRS[1].b);
`);
	assert c.ok;
	assert c.value.contains("MS_STRLIT_FLAG | 2");
	assert !c.value.contains("msArrayPayloadNew(");
}

test "an unread library const array of sized-array literals is dropped with its data" {
	const lib = "export type Limb = uint32[3];\nexport const ROWS: Limb[] = [[1, 2, 3], [4, 5, 6]];\nexport const USED: int32 = 7;\n";
	const main = "import { USED } from \"./rows\";\nconsole.log(USED);\n";
	const c = compileProjectToC([{ entryPath: "src/rows.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms");
	assert !c.contains("MS_STRLIT_FLAG | 2");
	assert !c.contains("msArrayPayloadNew(");
}

test "an unread read-only library const array is dropped with its data while its module still runs init" {
	const lib = "export const TABLE: Readonly<uint32[]> = [11, 22, 33];\nexport function pick(i: int32): uint32 { return TABLE[i]; }\nexport const START: string[] = [\"lib\", \"init\"].map((s) => s);\n";
	const main = "import { START } from \"./table\";\nconsole.log(START[0]);\n";
	const c = compileProjectToC([{ entryPath: "src/table.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms");
	assert c.contains("ZsrcZtableOms__Init000(void) {"), "the library module no longer runs init, so the pin no longer sees its exit";
	assert !c.contains("MS_STRLIT_FLAG | 3");
}

test "a mutable library const array is still destroyed at exit" {
	const lib = "export const ROWS: uint32[] = [11, 22, 33];\nexport const START: string[] = [\"lib\", \"init\"].map((s) => s);\n";
	const main = "import { ROWS, START } from \"./rows\";\nROWS.push(44);\nconsole.log(START[0], ROWS.length);\n";
	const c = compileProjectToC([{ entryPath: "src/rows.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms");
	assert c.contains("bakedExit");
}
