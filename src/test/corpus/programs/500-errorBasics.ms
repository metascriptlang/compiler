// Parity program — std Error across backends: construct, read .message,
// throw and catch it as a value. Pins the js prelude carrying Error
// (std/core/system/index.jms) so the two preludes cannot drift apart.

function boom(flag: boolean): string {
	if (flag) { throw new Error("bang"); }
	return "no";
}

function main(): void {
	const e = new Error("boom");
	console.log("msg=" + e.message);
	try {
		console.log("pre=" + boom(true));
	} catch (err) {
		console.log("caught");
	}
	console.log("post=" + boom(false));
}
main();
