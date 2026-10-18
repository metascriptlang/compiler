// @stdout: settle=2,pending generic=value,pending
// @skip-raiser: a finished Promise is read as its value on the Raiser VM, so instanceof on a union holding one is refused there

async function two(): Promise<number> { return 2; }

function settle(r: Promise<number> | number): string {
	if (r instanceof Promise) { return "pending"; }
	return (r + 1).toString();
}

function settleAny<T>(r: Promise<T> | T): string {
	if (r instanceof Promise) { return "pending"; }
	return "value";
}

console.log("settle=" + settle(1) + "," + settle(two())
	+ " generic=" + settleAny<number>(1) + "," + settleAny<number>(two()));
