// The --os=solana libm (runtime/freestanding/math.h) gives floor, ceil, trunc and fmod the
// results node gives for 1e300, -1e300, 2^53 + 1, NaN and the infinities, with no int64 cast
// past 2^63, and isnan/isinf/isfinite link without a libm behind them. pow follows C's pow
// table for zeros, infinities, NaN and exponents past 2^63, is exact for integer results, and
// stops the program on a positive base with a fractional exponent: exp and log are absent, and
// a link refusal inside pow fails every -O0 build that calls pow, integer exponents included.
// `**` and Math.pow reach it through msPowF64 (runtime/core/checkedArith.h), which gives
// ECMAScript's NaN for a NaN exponent and for a +-1 base with an infinite exponent, squares
// for an exponent of 2, and under MSOS_SOLANA leaves an exponent of 0.5 to this pow, since
// the header declares sqrt without a body.
//
// WHY A SUBPROCESS: no host build reads this header (host and --os=bare use the system libm),
// so the guard compiles a C probe against it with host clang under UBSan float-cast-overflow.
//
// RED PRE-FIX: UBSan stops floor(1e300) and pow(2, 1e300) at the int64 cast, isfinite is an
// undefined symbol, pow(2, 0.5) returns 1, the probe does not build without msPowF64, and
// msPowF64(2, 0.5) returns sqrt(2) from the host libm when its square root ignores MSOS_SOLANA.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, findOnPath } from "std/process";
import { writeFile, ensureDir } from "std/fs";

const root = cwd();
const dir = `${root}/out/guardFreestandingMath`;

const preamble = [
	"#include <math.h>",
	"#include <stdint.h>",
	"_Noreturn void msRaiseDivByZero(void);",
	"_Noreturn void msRaiseOverflow(void);",
	"_Noreturn void msRaiseRangeError(int64_t val, int64_t lo, int64_t hi);",
	"#include \"runtime/core/checkedArith.h\"",
	"int printf(const char*, ...);",
];

const probe = [
	...preamble,
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
	"\tsame(\"pow(2, 1e300)\", pow(2.0 * one, huge), inf);",
	"\tsame(\"pow(2, -1e300)\", pow(2.0 * one, -huge), 0.0);",
	"\tsame(\"pow(0.5, 1e300)\", pow(0.5 * one, huge), 0.0);",
	"\tsame(\"pow(-2, 1e300)\", pow(-2.0 * one, huge), inf);",
	"\tsame(\"pow(-1, 1e300)\", pow(-one, huge), 1.0);",
	"\tsame(\"pow(1+2^-52, 2^63)\", pow(0x1.0000000000001p0 * one, 0x1p63), inf);",
	"\tsame(\"pow(1-2^-53, 2^63)\", pow(0x1.fffffffffffffp-1 * one, 0x1p63), 0.0);",
	"\tsame(\"pow(2, NaN)\", pow(2.0 * one, nan), nan);",
	"\tsame(\"pow(NaN, 1)\", pow(nan, one), nan);",
	"\tsame(\"pow(NaN, 0)\", pow(nan, zero), 1.0);",
	"\tsame(\"pow(NaN, -0)\", pow(nan, -zero), 1.0);",
	"\tsame(\"pow(1, NaN)\", pow(one, nan), 1.0);",
	"\tsame(\"pow(1, Infinity)\", pow(one, inf), 1.0);",
	"\tsame(\"pow(-1, Infinity)\", pow(-one, inf), 1.0);",
	"\tsame(\"pow(-1, -Infinity)\", pow(-one, -inf), 1.0);",
	"\tsame(\"pow(0.5, Infinity)\", pow(0.5 * one, inf), 0.0);",
	"\tsame(\"pow(0.5, -Infinity)\", pow(0.5 * one, -inf), inf);",
	"\tsame(\"pow(-2, Infinity)\", pow(-2.0 * one, inf), inf);",
	"\tsame(\"pow(2, -Infinity)\", pow(2.0 * one, -inf), 0.0);",
	"\tsame(\"pow(-0, 3)\", pow(-zero, 3.0), -0.0);",
	"\tsame(\"pow(-0, 2)\", pow(-zero, 2.0), 0.0);",
	"\tsame(\"pow(-0, -3)\", pow(-zero, -3.0), -inf);",
	"\tsame(\"pow(-0, -2)\", pow(-zero, -2.0), inf);",
	"\tsame(\"pow(-0, 0.5)\", pow(-zero, 0.5), 0.0);",
	"\tsame(\"pow(-0, -0.5)\", pow(-zero, -0.5), inf);",
	"\tsame(\"pow(-0, -Infinity)\", pow(-zero, -inf), inf);",
	"\tsame(\"pow(-Infinity, 3)\", pow(-inf, 3.0), -inf);",
	"\tsame(\"pow(-Infinity, -3)\", pow(-inf, -3.0), -0.0);",
	"\tsame(\"pow(-Infinity, 2)\", pow(-inf, 2.0), inf);",
	"\tsame(\"pow(-Infinity, 0.5)\", pow(-inf, 0.5), inf);",
	"\tsame(\"pow(-Infinity, -0.5)\", pow(-inf, -0.5), 0.0);",
	"\tsame(\"pow(Infinity, -2)\", pow(inf, -2.0), 0.0);",
	"\tsame(\"pow(-8, 1/3)\", pow(-8.0 * one, 1.0 / 3.0), nan);",
	"\tsame(\"pow(-1, 2^53-1)\", pow(-one, 0x1.fffffffffffffp52), -1.0);",
	"\tsame(\"pow(-1, 1-2^53)\", pow(-one, -0x1.fffffffffffffp52), -1.0);",
	"\tsame(\"pow(3, 33)\", pow(3.0 * one, 33.0), 5559060566555523.0);",
	"\tsame(\"pow(10, 22)\", pow(10.0 * one, 22.0), 1e22);",
	"\tsame(\"pow(-2, 3)\", pow(-2.0 * one, 3.0), -8.0);",
	"\tsame(\"pow(-2, -3)\", pow(-2.0 * one, -3.0), -0.125);",
	"\tsame(\"pow(2, 1023)\", pow(2.0 * one, 1023.0), 0x1p1023);",
	"\tsame(\"pow(2, 1024)\", pow(2.0 * one, 1024.0), inf);",
	"\tsame(\"pow(2, -1074)\", pow(2.0 * one, -1074.0), 0x1p-1074);",
	"\tsame(\"pow(-2, -1073)\", pow(-2.0 * one, -1073.0), -0x1p-1073);",
	"\tsame(\"pow(2, -1075)\", pow(2.0 * one, -1075.0), 0.0);",
	"\tsame(\"msPowF64(1, NaN)\", msPowF64(one, nan), nan);",
	"\tsame(\"msPowF64(1, Infinity)\", msPowF64(one, inf), nan);",
	"\tsame(\"msPowF64(1, -Infinity)\", msPowF64(one, -inf), nan);",
	"\tsame(\"msPowF64(-1, Infinity)\", msPowF64(-one, inf), nan);",
	"\tsame(\"msPowF64(-1, -Infinity)\", msPowF64(-one, -inf), nan);",
	"\tsame(\"msPowF64(NaN, 0)\", msPowF64(nan, zero), 1.0);",
	"\tsame(\"msPowF64(-1, 1e300)\", msPowF64(-one, huge), 1.0);",
	"\tsame(\"msPowF64(-2, -1073)\", msPowF64(-2.0 * one, -1073.0), -0x1p-1073);",
	"\tsame(\"msPowF64(0.5, Infinity)\", msPowF64(0.5 * one, inf), 0.0);",
	"\tsame(\"msPowF64(49.283038373705544, 2)\", msPowF64(49.283038373705544 * one, 2.0), 2428.8178713441334);",
	"\tsame(\"msPowF64(-0, 2)\", msPowF64(-zero, 2.0), 0.0);",
	"\tsame(\"msPowF64(-Infinity, 2)\", msPowF64(-inf, 2.0), inf);",
	"\tsame(\"msPowF64(-0, 0.5)\", msPowF64(-zero, 0.5), 0.0);",
	"\tsame(\"msPowF64(-Infinity, 0.5)\", msPowF64(-inf, 0.5), inf);",
	"\tsame(\"msPowF64(-4, 0.5)\", msPowF64(-4.0 * one, 0.5), nan);",
	"\tholds(\"isfinite(1e300)\", isfinite(huge));",
	"\tholds(\"!isfinite(NaN)\", !isfinite(nan));",
	"\tholds(\"isnan(NaN)\", isnan(nan));",
	"\tholds(\"isinf(-Infinity)\", isinf(-inf));",
	"\tif (failures == 0) printf(\"GUARD-OK\\n\");",
	"\treturn failures != 0;",
	"}",
	"",
].join("\n");

const fractionalPow = [
	...preamble,
	"int main(void) {",
	"\tvolatile double half = 0.5;",
	"\tprintf(\"msPowF64(2, 0.5) returned %.17g\\n\", msPowF64(2.0, half));",
	"\treturn 0;",
	"}",
	"",
].join("\n");

function firstLines(r: ExecFileResult): string {
	const lines = `${r.errorOutput}${r.output}`.split("\n");
	return lines.slice(0, 8).join("\n");
}

function buildAndRun(name: string, source: string): ExecFileResult {
	writeFile(`${dir}/${name}.c`, source);
	const flags = ["-std=c11", "-ffreestanding", "-fno-builtin", "-isystem", `${root}/runtime/freestanding`, "-I", root, "-DMSOS_SOLANA",
		"-fsanitize=float-cast-overflow", "-fno-sanitize-recover=all", `${name}.c`, "-o", name];
	const built = execFileResult("clang", flags, dir);
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL the ${name} probe against runtime/freestanding/math.h did not build:\n${firstLines(built)}`);
		exit(1);
	}
	return execFileResult(`${dir}/${name}`, [], dir);
}

if (findOnPath("clang") == "") {
	console.log("GUARD-FAIL no clang on PATH: the header probe needs a host C compiler");
	exit(1);
}
ensureDir(dir);
const ran = buildAndRun("probe", probe);
console.log(ran.output.trim());
if (ran.exitCode != 0 || !ran.output.contains("GUARD-OK")) {
	console.log(`GUARD-FAIL the probe exited ${ran.exitCode}:\n${firstLines(ran)}`);
	exit(1);
}
const refused = buildAndRun("fractionalPow", fractionalPow);
if (refused.exitCode == 0 && refused.signal == 0) {
	console.log(`GUARD-FAIL a fractional exponent did not stop the program:\n${firstLines(refused)}`);
	exit(1);
}
