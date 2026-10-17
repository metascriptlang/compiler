// Promise.reject takes an Error and the catch that awaits it receives that Error on every
// backend: a plain Error, a subclass whose own field survives, and a rejection that crosses an
// awaiting async function after an earlier one was caught (the future holds its own reference).
// @stdout: caught plain|caught coded 7|caught deep|done
// @exit: 0

class CodeError extends Error {
	code: int32;
	constructor(message: string, code: int32) {
		super(message);
		this.code = code;
	}
}

async function rejectDeep(): Promise<void> {
	await Promise.reject(new Error("deep"));
}

let log = "";
try { await Promise.reject(new Error("plain")); } catch (e) { log += `caught ${e.message}|`; }
try {
	await Promise.reject(new CodeError("coded", 7));
} catch (e) {
	if (e instanceof CodeError) log += `caught ${e.message} ${(e as CodeError).code}|`;
	else log += `caught a plain Error: ${e.message}|`;
}
try { await rejectDeep(); } catch (e) { log += `caught ${e.message}|`; }
console.log(`${log}done`);
