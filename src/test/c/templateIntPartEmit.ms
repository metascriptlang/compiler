// E2E C: a template literal formats an integer part through the integer path,
// drops its empty literal parts and joins in one concat call.

import { compileToC } from "../helpers";

function emitFor(body: string): string {
	const c = compileToC(body);
	return c.ok ? c.value : "";
}

test "E2E C: an integer part skips the radix formatter and an empty head is dropped" {
	const c = emitFor(`
		const WORDS = ["alpha", "beta"];
		let n = 0;
		for (let i: int32 = 0; i < 2; i++) n += \`\${WORDS[i]}:\${i}\`.length;
		console.log(n);
	`);
	assert c != "";
	assert !c.contains("msNumberToStringRadix");
	assert c.contains("msIntToString(");
	assert c.contains("msStringConcatArr(") && c.contains(", 3)");
}

test "E2E C: String of an integer and a number format on the decimal path" {
	const c = emitFor(`
		let n = 0;
		for (let i: int32 = 0; i < 2; i++) n += String(i).length;
		const f: number = n / 3;
		const u: uint64 = 5;
		console.log(String(f), String(u), n);
	`);
	assert c != "";
	assert !c.contains("msNumberToStringRadix");
	assert !c.contains("msUint64ToStringRadix");
}

test "E2E C: a single interpolated number is one formatter call with no concat" {
	const c = emitFor(`
		const x: int32 = 3;
		console.log(\`\${x}\`);
	`);
	assert c != "";
	assert !c.contains("msStringConcat");
	assert !c.contains("msNumberToStringRadix");
}
