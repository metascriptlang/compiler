// Parity program — an async try whose finally calls through a counted borrow
// (a method that calls a closure, a free function) runs that finally correctly
// at every return that crosses the split try: a return in try, in catch, and
// before or after an await, with the await in the try or in the finally.
//
// @stdout: ok 4
// @stdout: body 8
// @stdout: e2
// @stdout: b4 2
// @stdout: fin2,fin3,stopped,stopped,stopped,stopped,stopped,stopped,stopped,stopped,stopped
// @exit: 0

const log: string[] = [];
async function work(n: int32): Promise<int32> { return n * 2; }

async function viaAwait(n: int32): Promise<string> {
	try { const v = await work(n); return "ok " + v; } catch (e) { return "caught"; } finally { log.push("fin" + (n + 1)); }
}

class Router {
	stop: () => void = (): void => { log.push("stopped"); };
	dispose(): void { this.stop(); }
}
function release(r: Router): void { r.stop(); }

async function serve(early: boolean): Promise<string> {
	const router = new Router();
	try {
		if (early) { return "early"; }
		return "body page";
	} finally {
		router.dispose();
	}
}

async function serveAwait(early: boolean): Promise<string> {
	const router = new Router();
	try {
		if (early) { return "early"; }
		return "body " + await work(4);
	} finally {
		router.dispose();
	}
}

async function catchAndTry(early: boolean): Promise<string> {
	const router = new Router();
	try {
		await work(1);
		if (early) { return "e" + (await work(1)); }
		throw new Error("x");
	} catch (e) {
		return "c";
	} finally {
		router.dispose();
	}
}

async function awaitInFinally(early: boolean): Promise<string> {
	const router = new Router();
	try {
		if (early) { return "e3"; }
		return "b3";
	} finally {
		await work(1);
		router.dispose();
	}
}

async function freeInFinally(early: boolean): Promise<string> {
	const router = new Router();
	try {
		if (early) { return "e4"; }
		return "b4 " + await work(1);
	} finally {
		release(router);
	}
}

async function main(): Promise<void> {
	console.log(await viaAwait(1));
	console.log(await viaAwait(2));
	console.log(await serve(true));
	console.log(await serveAwait(false));
	console.log(await serveAwait(true));
	console.log(await catchAndTry(false));
	console.log(await catchAndTry(true));
	console.log(await awaitInFinally(true));
	console.log(await awaitInFinally(false));
	console.log(await freeInFinally(true));
	console.log(await freeInFinally(false));
	console.log(log.join(","));
}
main();
