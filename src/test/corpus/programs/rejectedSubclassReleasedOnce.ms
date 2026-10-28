// @skip-js: a sync function awaits here, which the JS backend refuses (checker/syncAwait.ms)
// @stdout: sync coded 7|unread|async coded 7|stored coded 7|done
// note: Promise.reject of a freshly built Error subclass hands the promise its own count and drops the caller's, as it does for a plain Error: awaited from a sync function, with a catch that never reads the error, from an async function and through a stored promise, every error is released once.

class CodeError extends Error {
	code: int32;
	constructor(message: string, code: int32) {
		super(message);
		this.code = code;
	}
}

let log = "";

function syncReader(): void {
	try { await Promise.reject(new CodeError("coded", 7)); } catch (e) { log += `sync ${e.message} ${(e as CodeError).code}|`; }
}

function unreadError(): void {
	try { await Promise.reject(new CodeError("coded", 8)); } catch (e) { log += "unread|"; }
}

async function asyncReader(): Promise<void> {
	try { await Promise.reject(new CodeError("coded", 7)); } catch (e) { log += `async ${e.message} ${(e as CodeError).code}|`; }
}

function storedReader(): void {
	const p: Promise<void> = Promise.reject(new CodeError("coded", 7));
	try { await p; } catch (e) { log += `stored ${e.message} ${(e as CodeError).code}|`; }
}

syncReader();
unreadError();
asyncReader().then((): void => {
	storedReader();
	console.log(`${log}done`);
});
