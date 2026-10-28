// @stdout: then1|after-void|int2|after-actor
// @serial
// @ledger-slack(Counter) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: `await e` of a non-awaitable e yields once with e's own type, like `await Promise.resolve(e)`; a void actor method is sent, not waited for.

function nothing(): void {}
function two(): int32 { return 2; }

actor Counter {
	n: int32 = 0;
	reset(): void { this.n = 0; }
}

async function main(): Promise<void> {
	const order: string[] = [];
	Promise.resolve(0).then((v: int32): void => { order.push("then1"); });
	await nothing();
	order.push("after-void");
	const x = await two();
	order.push("int" + x.toString());
	const c = new Counter();
	await c.reset();
	order.push("after-actor");
	console.log(order.join("|"));
}
main();
