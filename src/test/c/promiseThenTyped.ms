import { compileToC } from "../helpers";

test "a then callback on a number promise goes through the double variant" {
	const result = compileToC("async function num(): Promise<number> { return 2.5; }\nlet n = 0.0;\nnum().then((v: number): void => { n = v; });");
	assert result.ok;
	assert result.value.contains("msFutureThen_double(");
}

test "a then callback on a string promise goes through the msString variant" {
	const result = compileToC("async function text(): Promise<string> { return \"hi\"; }\nlet t = \"\";\ntext().then((v: string): void => { t = v; });");
	assert result.ok;
	assert result.value.contains("msFutureThen_msString(");
}

test "a then callback on a struct promise unboxes through its own variant" {
	const result = compileToC("struct Pair { a: int32; b: int32; }\nasync function pair(): Promise<Pair> { return { a: 3, b: 4 }; }\nlet p: Pair = { a: 0, b: 0 };\npair().then((v: Pair): void => { p = v; });");
	assert result.ok;
	assert result.value.contains("MS_DEFINE_FUTURE_THEN_BOXED(msFutureThenBoxed_Pair");
}

test "a then callback on a struct wider than three words takes it by pointer and destroys it after the call" {
	const result = compileToC("struct Batch { paths: string[]; label: string; count: int32; }\nasync function next(): Promise<Batch> { return { paths: [\"a\"], label: \"l\", count: 1 }; }\nlet total: int32 = 0;\nnext().then((b: Batch): void => { total = b.count; });");
	assert result.ok;
	assert result.value.contains("MS_DEFINE_FUTURE_THEN_BOXED(msFutureThenBoxedRef_Batch");
	assert result.value.contains(", MS_PASS_REF, ");
	assert !result.value.contains(", MS_PASS_REF, MS_NO_DROP)");
}
