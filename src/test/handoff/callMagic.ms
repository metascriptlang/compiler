// A runtime routine whose call the C backend replaces is declared with its
// call-site signature and a @builtin tag; the backend keys the replacement on
// that tag. These pin the replacement still fires once the routine is declared.

import { compileToC } from "../helpers";

test "a string spawn fills the typed future slot by offset" {
	const src = `
async function run(): Promise<void> {
	const futs: Promise<string>[] = [];
	futs.push(spawn(() => { return "pt"; }));
	for (const f of futs) {
		const s = await f;
		console.log(s);
	}
}
await run();
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("offsetof(msFuture_msString, value)");
	assert !r.value.contains("msSpawnInto(void*");
}

test "a three-part concat passes a stack array, not variadic strings" {
	const src = `
export function label(a: string, b: string): string {
	return a + "-" + b;
}
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("msStringConcatArr(_mscc");
}
