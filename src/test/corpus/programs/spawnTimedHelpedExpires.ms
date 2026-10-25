// @stdout: loop waiter timed out
// @stdout: worker waiter timed out
// @stdout: group timed out
// @exit: 0
// @skip-js: a spawn deadline is enforced by the C runtime's pool wait
// @skip-raiser
// note: a timed await whose waiter runs the child itself, past the deadline, throws instead of returning the late value; on the loop thread, on a pool worker and through Promise.all (old runtime: the value came back)

function slow(): int32 {
	const until = Date.now() + 300;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 7;
	return 5;
}

function timedOut(): boolean {
	try {
		const v = await spawn((): int32 => slow(), { timeout: 20 });
		console.log(`late ${v}`);
		return false;
	} catch (e) {
		return true;
	}
}

function groupTimedOut(): boolean {
	try {
		const g = await Promise.all([spawn((): int32 => slow(), { timeout: 20 }), spawn((): int32 => slow())]);
		console.log(`late ${g[0] + g[1]}`);
		return false;
	} catch (e) {
		return true;
	}
}

console.log(timedOut() ? "loop waiter timed out" : "loop waiter returned");
const onWorker = await spawn(timedOut);
console.log(onWorker ? "worker waiter timed out" : "worker waiter returned");
console.log(groupTimedOut() ? "group timed out" : "group returned");
