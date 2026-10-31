// The JS string prelude reaches the native operation for these calls instead of bounds helpers
// or a BigInt parse. Their results on non-ASCII input equal C's in
// corpus/programs/1241-stringNativeOpsMatrix.ms.
//
// The compiler under test is $MSC, else ./msc; the pins read the JS it emits, std included.

import { cwd, env, execFileCapture } from "std/process";
import { writeFile, readFile, ensureDir } from "std/fs";

const source = "const s = \"Ab\";\nconsole.log(s.substring(1, 2) + s.charAt(1) + s.charCodeAt(1).toString() + s.parseInt().toString());\n";

function compilerPath(): string {
	const named = env.get("MSC");
	if (named != "") return named.startsWith("/") ? named : `${cwd()}/${named}`;
	return `${cwd()}/msc`;
}

function emittedJs(): string {
	const dir = `${cwd()}/out/stringNative-${performance.now().toString()}`;
	ensureDir(dir);
	if (!writeFile(`${dir}/main.ms`, source).ok) return "error: cannot write the program";
	const r = execFileCapture(compilerPath(), ["build", "--target=js", `--output=${dir}/main.js`, `${dir}/main.ms`], dir);
	if (!r.ok) return "error: " + r.error.output + r.error.errorOutput;
	const js = readFile(`${dir}/main.js`);
	return js.ok ? js.value : "error: cannot read the emitted JS";
}

test "substring calls the native substring" {
	const js = emittedJs();
	assert !js.startsWith("error:"), js;
	assert js.contains(".substring(");
}

test "charCodeAt reads the native code unit and maps NaN to -1" {
	const js = emittedJs();
	assert !js.startsWith("error:"), js;
	assert js.contains("c >= 0 ? c : -1");
}

test "parseInt reads a safe integer with the native parseInt" {
	const js = emittedJs();
	assert !js.startsWith("error:"), js;
	assert js.contains("Number.parseInt(");
}
