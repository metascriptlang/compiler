// Runs the JS that `msc build --target=js` emits, with and without --danger, and compares each
// integer result with the two's-complement value computed by hand. Text pins for the same
// lowering live in intArith.ms; C --danger is deliberately absent (signed overflow is
// undefined there).
//
// The compiler under test is $MSC, else ./msc.

import { cwd, env, execFileCapture } from "std/process";
import { writeFile, ensureDir } from "std/fs";

const trap = "trap";

// name, type, x, y, body, printed value, expected under --danger, expected in the default
// build ("=" repeats the --danger value).
type Row = string[];

const rows: Row[] = [
	["i32Add", "int32", "2147483647", "1", "r = x + y;", "${r}", "-2147483648", trap],
	["i32AddOk", "int32", "2147483646", "1", "r = x + y;", "${r}", "2147483647", "="],
	["i32Sub", "int32", "-2147483648", "1", "r = x - y;", "${r}", "2147483647", trap],
	["i32SubOk", "int32", "-2147483647", "1", "r = x - y;", "${r}", "-2147483648", "="],
	["i32MulMax", "int32", "2147483647", "2147483647", "r = x * y;", "${r}", "1", trap],
	["i32MulTwo", "int32", "2147483647", "2", "r = x * y;", "${r}", "-2", trap],
	["i32MulOk", "int32", "46340", "46340", "r = x * y;", "${r}", "2147395600", "="],
	["i32MulOver", "int32", "46341", "46341", "r = x * y;", "${r}", "-2147479015", trap],
	["i32NegMin", "int32", "-2147483648", "0", "r = -x;", "${r}", "-2147483648", trap],
	["i32NegOk", "int32", "2147483647", "0", "r = -x;", "${r}", "-2147483647", "="],
	["i16Add", "int16", "32767", "1", "r = x + y;", "${r}", "-32768", trap],
	["i16Sub", "int16", "-32768", "1", "r = x - y;", "${r}", "32767", trap],
	["i16Mul", "int16", "32767", "32767", "r = x * y;", "${r}", "1", trap],
	["i16NegMin", "int16", "-32768", "0", "r = -x;", "${r}", "-32768", trap],
	["i8Add", "int8", "127", "1", "r = x + y;", "${r}", "-128", trap],
	["i8AddOk", "int8", "126", "1", "r = x + y;", "${r}", "127", "="],
	["i8Sub", "int8", "-128", "1", "r = x - y;", "${r}", "127", trap],
	["i8Mul", "int8", "127", "127", "r = x * y;", "${r}", "1", trap],
	["i8NegMin", "int8", "-128", "0", "r = -x;", "${r}", "-128", trap],
	["i64Add", "int64", "9223372036854775807", "1", "r = x + y;", "${r}", "-9223372036854775808", trap],
	["i64AddOk", "int64", "9223372036854775806", "1", "r = x + y;", "${r}", "9223372036854775807", "="],
	["i64Sub", "int64", "-9223372036854775808", "1", "r = x - y;", "${r}", "9223372036854775807", trap],
	["i64MulMax", "int64", "9223372036854775807", "9223372036854775807", "r = x * y;", "${r}", "1", trap],
	["i64MulTwo", "int64", "9223372036854775807", "2", "r = x * y;", "${r}", "-2", trap],
	["i64NegMin", "int64", "-9223372036854775808", "0", "r = -x;", "${r}", "-9223372036854775808", trap],
	["i32PostInc", "int32", "2147483647", "0", "r = x++;", "${r},${x}", "2147483647,-2147483648", trap],
	["i32PreInc", "int32", "2147483647", "0", "r = ++x;", "${r},${x}", "-2147483648,-2147483648", trap],
	["i32PostDec", "int32", "-2147483648", "0", "r = x--;", "${r},${x}", "-2147483648,2147483647", trap],
	["i32PreDec", "int32", "-2147483648", "0", "r = --x;", "${r},${x}", "2147483647,2147483647", trap],
	["i32PostIncOk", "int32", "2147483646", "0", "r = x++;", "${r},${x}", "2147483646,2147483647", "="],
	["i64PostInc", "int64", "9223372036854775807", "0", "r = x++;", "${r},${x}", "9223372036854775807,-9223372036854775808", trap],
	["i64PreInc", "int64", "9223372036854775807", "0", "r = ++x;", "${r},${x}", "-9223372036854775808,-9223372036854775808", trap],
	["i64PostDec", "int64", "-9223372036854775808", "0", "r = x--;", "${r},${x}", "-9223372036854775808,9223372036854775807", trap],
	["i64PreDec", "int64", "-9223372036854775808", "0", "r = --x;", "${r},${x}", "9223372036854775807,9223372036854775807", trap],
	["i32AddAssign", "int32", "2147483647", "1", "x += y;", "${x}", "-2147483648", trap],
	["i32MulAssign", "int32", "1073741824", "2", "x *= y;", "${x}", "-2147483648", trap],
	["i64MulAssign", "int64", "4611686018427387904", "2", "x *= y;", "${x}", "-9223372036854775808", trap],
	["i8AddAssign", "int8", "127", "1", "x += y;", "${x}", "-128", trap],
	["i32Pow31", "int32", "2", "31", "r = x ** y;", "${r}", "-2147483648", trap],
	["i32Pow21", "int32", "3", "21", "r = x ** y;", "${r}", "1870418611", trap],
	["i32Pow30", "int32", "2", "30", "r = x ** y;", "${r}", "1073741824", "="],
	["i8Pow7", "int8", "2", "7", "r = x ** y;", "${r}", "-128", trap],
	["i8Pow5", "int8", "3", "5", "r = x ** y;", "${r}", "-13", trap],
	["i8Pow6", "int8", "2", "6", "r = x ** y;", "${r}", "64", "="],
	["i64Pow63", "int64", "2", "63", "r = x ** y;", "${r}", "-9223372036854775808", trap],
	["charPostInc", "char", "255", "0", "r = x++;", "${r as uint8},${x as uint8}", "255,0", trap],
	["charPreDec", "char", "0", "0", "r = --x;", "${r as uint8},${x as uint8}", "255,255", trap],
	["charStepOk", "char", "254", "0", "r = ++x;", "${r as uint8},${x as uint8}", "255,255", "="],
	["u8Add", "uint8", "255", "1", "r = x + y;", "${r}", "0", "="],
	["u8Sub", "uint8", "0", "1", "r = x - y;", "${r}", "255", "="],
	["u8PostInc", "uint8", "255", "0", "r = x++;", "${r},${x}", "255,0", "="],
	["u16Sub", "uint16", "0", "1", "r = x - y;", "${r}", "65535", "="],
	["u32Add", "uint32", "4294967295", "1", "r = x + y;", "${r}", "0", "="],
	["u32Sub", "uint32", "0", "1", "r = x - y;", "${r}", "4294967295", "="],
	["u64Add", "uint64", "18446744073709551615", "1", "r = x + y;", "${r}", "0", "="],
	["u64Sub", "uint64", "0", "1", "r = x - y;", "${r}", "18446744073709551615", "="],
];

function programSource(): string {
	let out = "import { argv } from \"std/process\";\nconst c = argv[1];\n";
	for (const row of rows) {
		const cast = row[1] == "char" ? " as char" : "";
		out += `if (c == "${row[0]}") { let x: ${row[1]} = ${row[2]}${cast}; let y: ${row[1]} = ${row[3]}${cast}; let r: ${row[1]} = x; ${row[4]} console.log(\`${row[5]}\`); }\n`;
	}
	return out;
}

const built: Map<boolean, string> = new Map();

function compilerPath(): string {
	const named = env.get("MSC");
	if (named != "") return named.startsWith("/") ? named : `${cwd()}/${named}`;
	return `${cwd()}/msc`;
}

function buildJs(danger: boolean): string {
	const cached = built.get(danger);
	if (cached != null) return cached;
	const dir = `${cwd()}/out/intArithRun-${danger ? "danger" : "default"}-${performance.now().toString()}`;
	ensureDir(dir);
	const src = `${dir}/main.ms`;
	if (!writeFile(src, programSource()).ok) return "error: cannot write " + src;
	const args = ["build", "--target=js", `--output=${dir}/main.js`, src];
	if (danger) args.push("--danger");
	const r = execFileCapture(compilerPath(), args, dir);
	if (!r.ok) return "error: " + r.error.output + r.error.errorOutput;
	built.set(danger, `${dir}/main.js`);
	return `${dir}/main.js`;
}

function outcomes(danger: boolean, names: string[]): string[] {
	const js = buildJs(danger);
	if (js.startsWith("error:")) return [js];
	const bad: string[] = [];
	for (const row of rows) {
		if (!names.some((n: string): boolean => row[0].startsWith(n))) continue;
		const want = danger ? row[6] : (row[7] == "=" ? row[6] : row[7]);
		const r = execFileCapture("node", [js, row[0]]);
		const got = r.ok ? r.value.trim() : (r.error.errorOutput.contains("over- or underflow") ? trap : "crash: " + r.error.errorOutput);
		if (got != want) bad.push(`${row[0]}: want ${want}, got ${got}`);
	}
	return bad;
}


test "danger int32 add, sub, mul and negation wrap at the bounds" {
	const bad = outcomes(true, ["i32Add", "i32Sub", "i32Mul", "i32Neg"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger int8 and int16 arithmetic wraps at the bounds" {
	const bad = outcomes(true, ["i8Add", "i8Sub", "i8Mul", "i8Neg", "i16"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger int64 add, sub, mul and negation wrap at the bounds" {
	const bad = outcomes(true, ["i64Add", "i64Sub", "i64Mul", "i64Neg"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger postfix and prefix steps wrap on int32 and int64" {
	const bad = outcomes(true, ["i32Post", "i32Pre", "i64Post", "i64Pre"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger compound assignment wraps" {
	const bad = outcomes(true, ["i32AddAssign", "i32MulAssign", "i64MulAssign", "i8AddAssign"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger power wraps on int32, int8 and int64" {
	const bad = outcomes(true, ["i32Pow", "i8Pow", "i64Pow"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger char steps wrap" {
	const bad = outcomes(true, ["char"]);
	assert bad.length == 0, bad.join("\n");
}

test "danger leaves the unsigned widths wrapping" {
	const bad = outcomes(true, ["u8", "u16", "u32", "u64"]);
	assert bad.length == 0, bad.join("\n");
}

test "default build traps int32 at and past its bounds and keeps in-range results" {
	const bad = outcomes(false, ["i32"]);
	assert bad.length == 0, bad.join("\n");
}

test "default build traps int8, int16 and int64 past their bounds" {
	const bad = outcomes(false, ["i8", "i16", "i64"]);
	assert bad.length == 0, bad.join("\n");
}

test "default build traps a char step past its byte" {
	const bad = outcomes(false, ["char"]);
	assert bad.length == 0, bad.join("\n");
}

test "default build wraps the unsigned widths" {
	const bad = outcomes(false, ["u8", "u16", "u32", "u64"]);
	assert bad.length == 0, bad.join("\n");
}
