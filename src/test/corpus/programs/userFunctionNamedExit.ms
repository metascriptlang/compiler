// @stdout: user exit 3 after 4 member 6 local 8
// note: a function, a method or a local named `exit` or `process` is the author's own: only the std `exit` and `process.exit` stop the program, on every backend including the Raiser VM.

function exit(code: int32): int32 {
	return code + 1;
}

class Shell {
	exit(code: int32): int32 {
		return code * 2;
	}
}

function viaLocal(): int32 {
	const process = new Shell();
	return process.exit(4);
}

const r = exit(3);
const m = new Shell().exit(3);
console.log(`user exit 3 after ${r} member ${m} local ${viaLocal()}`);
