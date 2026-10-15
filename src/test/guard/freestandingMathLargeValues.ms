// The --os=solana libm (runtime/freestanding/math.h) gives floor, ceil, trunc and fmod the
// results node gives for 1e300, -1e300, 2^53 + 1, NaN and the infinities, with no int64 cast
// past 2^63, and isnan/isinf/isfinite link without a libm behind them.
//
// WHY A SUBPROCESS: no host build reads this header (host and --os=bare use the system libm),
// so the guard compiles a C probe against it with host clang under UBSan float-cast-overflow.
//
// RED PRE-FIX: UBSan stops floor(1e300) at the int64 cast, and isfinite is an undefined symbol.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, findOnPath } from "std/process";
import { writeFile, ensureDir } from "std/fs";

const root = cwd();
const dir = `${root}/out/guardFreestandingMath`;

const probe = [
	"#include <math.h>",
	"int printf(const char*, ...);",
	"static int failures;",
	"static void same(const char* what, double got, double want) {",
	"\tint bothNan = got != got && want != want;",
	"\tint equal = got == want && __builtin_signbit(got) == __builtin_signbit(want);",
	"\tif (bothNan || equal) return;",
	"\tprintf(\"GUARD-FAIL %s got %.17g want %.17g\\n\", what, got, want);",
	"\tfailures++;",
	"}",
	"static void holds(const char* what, int got) {",
	"\tif (got) return;",
	"\tprintf(\"GUARD-FAIL %s\\n\", what);",
	"\tfailures++;",
	"}",
	"int main(void) {",
	"\tvolatile double huge = 1e300, past = 9007199254740993.0, zero = 0.0, one = 1.0;",
	"\tdouble nan = zero / zero, inf = one / zero;",
	"\tsame(\"floor(1e300)\", floor(huge), 1e300);",
	"\tsame(\"ceil(1e300)\", ceil(huge), 1e300);",
	"\tsame(\"trunc(1e300)\", trunc(huge), 1e300);",
	"\tsame(\"floor(-1e300)\", floor(-huge), -1e300);",
	"\tsame(\"ceil(-1e300)\", ceil(-huge), -1e300);",
	"\tsame(\"trunc(-1e300)\", trunc(-huge), -1e300);",
	"\tsame(\"floor(2^53+1)\", floor(past), 9007199254740992.0);",
	"\tsame(\"ceil(2^53+1)\", ceil(past), 9007199254740992.0);",
	"\tsame(\"floor(NaN)\", floor(nan), nan);",
	"\tsame(\"ceil(NaN)\", ceil(nan), nan);",
	"\tsame(\"trunc(NaN)\", trunc(nan), nan);",
	"\tsame(\"floor(Infinity)\", floor(inf), inf);",
	"\tsame(\"ceil(-Infinity)\", ceil(-inf), -inf);",
	"\tsame(\"floor(-0.5)\", floor(-0.5 * one), -1.0);",
	"\tsame(\"ceil(-0.5)\", ceil(-0.5 * one), -0.0);",
	"\tsame(\"trunc(-0.5)\", trunc(-0.5 * one), -0.0);",
	"\tsame(\"floor(2.5)\", floor(2.5 * one), 2.0);",
	"\tsame(\"ceil(2.5)\", ceil(2.5 * one), 3.0);",
	"\tsame(\"floor(-0)\", floor(-zero), -0.0);",
	"\tsame(\"fmod(1e300, 3)\", fmod(huge, 3.0), 0.0);",
	"\tsame(\"fmod(-1e300, 3)\", fmod(-huge, 3.0), -0.0);",
	"\tsame(\"fmod(1e300, 7)\", fmod(huge, 7.0), 1.0);",
	"\tsame(\"fmod(1e300, 1e-300)\", fmod(huge, 1e-300), 4.891554850853602e-301);",
	"\tsame(\"fmod(2^53+1, 10)\", fmod(past, 10.0), 2.0);",
	"\tsame(\"fmod(-5.5, 2)\", fmod(-5.5 * one, 2.0), -1.5);",
	"\tsame(\"fmod(2^32*3+5.75, 2^32)\", fmod(12884901893.75 * one, 4294967296.0), 5.75);",
	"\tsame(\"fmod(max, 5e-324)\", fmod(1.7976931348623157e308 * one, 5e-324), 0.0);",
	"\tsame(\"fmod(NaN, 3)\", fmod(nan, 3.0), nan);",
	"\tsame(\"fmod(Infinity, 3)\", fmod(inf, 3.0), nan);",
	"\tsame(\"fmod(3, 0)\", fmod(3.0 * one, zero), nan);",
	"\tsame(\"fmod(3, Infinity)\", fmod(3.0 * one, inf), 3.0);",
	"\tsame(\"fmod(-0, 3)\", fmod(-zero, 3.0), -0.0);",
	"\tholds(\"isfinite(1e300)\", isfinite(huge));",
	"\tholds(\"!isfinite(NaN)\", !isfinite(nan));",
	"\tholds(\"isnan(NaN)\", isnan(nan));",
	"\tholds(\"isinf(-Infinity)\", isinf(-inf));",
	"\tif (failures == 0) printf(\"GUARD-OK\\n\");",
	"\treturn failures != 0;",
	"}",
	"",
].join("\n");

function firstLines(r: ExecFileResult): string {
	const lines = `${r.errorOutput}${r.output}`.split("\n");
	return lines.slice(0, 8).join("\n");
}

if (findOnPath("clang") == "") {
	console.log("GUARD-FAIL no clang on PATH: the header probe needs a host C compiler");
	exit(1);
}
ensureDir(dir);
writeFile(`${dir}/probe.c`, probe);
const flags = ["-std=c11", "-ffreestanding", "-fno-builtin", "-isystem", `${root}/runtime/freestanding`,
	"-fsanitize=float-cast-overflow", "-fno-sanitize-recover=all", "probe.c", "-o", "probe"];
const built = execFileResult("clang", flags, dir);
if (built.exitCode != 0) {
	console.log(`GUARD-FAIL the probe against runtime/freestanding/math.h did not build:\n${firstLines(built)}`);
	exit(1);
}
const ran = execFileResult(`${dir}/probe`, [], dir);
console.log(ran.output.trim());
if (ran.exitCode != 0 || !ran.output.contains("GUARD-OK")) {
	console.log(`GUARD-FAIL the probe exited ${ran.exitCode}:\n${firstLines(ran)}`);
	exit(1);
}
