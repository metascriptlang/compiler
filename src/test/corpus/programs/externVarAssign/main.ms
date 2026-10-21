// Parity program — `extern var` and `extern let` bind a writable C lvalue: assignment and
// update write the C object itself, observed by a C getter, while `extern const` stays read-only.
// Axes: `var` on a plain C global, `let` with a `from` name on errno (a thread-local macro),
// plain assignment, compound assignment and increment, at top level and inside a function.
//
// @skip-js: these externs bind C symbols; the JS backend has no C linkage
// @xfail(raiser): Raiser evaluates no extern variable, read or written (`cannot evaluate at comptime: declaration node is ExternDecl`)
// @stdout: 7|8|9|0|5|6
// @exit: 0

@include("./ffi.h");

extern var corpusExternCounter: int32;
extern let nativeError: int32 from "errno";
extern function corpusReadCounter(): int32;
extern function corpusReadErrno(): int32;

function bump(): void {
	corpusExternCounter += 1;
}

corpusExternCounter = 7;
const first = corpusReadCounter();
bump();
const second = corpusReadCounter();
corpusExternCounter++;
nativeError = 0;
const cleared = corpusReadErrno();
nativeError = 5;
const set = corpusReadErrno();
nativeError += 1;
console.log(`${first}|${second}|${corpusReadCounter()}|${cleared}|${set}|${corpusReadErrno()}`);
