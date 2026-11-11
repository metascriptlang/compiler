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

test "an int32 and a uint32 formatted in another radix take the integer kernel, not the double one" {
	const c = emitFor(`
		const x: int32 = -255;
		const y: uint32 = 4294967295;
		console.log(x.toString(16), y.toString(16));
	`);
	assert c != "";
	assert c.contains("msIntToStringRadix");
	assert !c.contains("msNumberToStringRadix");
}

test "console.log of an int8, a uint32 and an int32 | undefined formats through the integer path, never the double one" {
	const c = emitFor(`
		const a: int8 = -128;
		const b: uint32 = 4294967295;
		const m: int32 | undefined = 7;
		console.log(a, b);
		console.log(m);
	`);
	assert c != "";
	assert c.contains("msIntToString(");
	assert !c.contains("msNumberToString(");
}

test "appending an int32 to a string formats through the integer path" {
	const c = emitFor(`
		const a: int32 = -7;
		let s = "n=";
		s += a;
		console.log(s);
	`);
	assert c != "";
	assert c.contains("msIntToString(");
	assert !c.contains("msNumberToString(");
}
