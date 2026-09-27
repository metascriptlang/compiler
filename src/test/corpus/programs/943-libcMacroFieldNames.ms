// @stdout: 0 out err 21 24
// note: fields and parameters named after standard-header macros are escaped on C (codegen-c-7: the preprocessor rewrote them and the build failed).

interface Streams {
	stdin: int32;
	stdout: string;
	stderr: string;
}
interface Macros {
	errno: int32;
	EOF: int32;
	NAN: int32;
	INFINITY: int32;
	assert: int32;
	offsetof: int32;
}
function withParams(errno: int32, EOF: int32, NAN: int32): int32 { return errno + EOF + NAN; }
const s: Streams = { stdin: 0, stdout: "out", stderr: "err" };
const m: Macros = { errno: 1, EOF: 2, NAN: 3, INFINITY: 4, assert: 5, offsetof: 6 };
const sum = m.errno + m.EOF + m.NAN + m.INFINITY + m.assert + m.offsetof;
console.log(`${s.stdin} ${s.stdout} ${s.stderr} ${sum} ${withParams(7, 8, 9)}`);
