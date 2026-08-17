// @exit: 1
// @skip-js: sleepAsync is not bound in the js prelude yet; node would exit 1 with its own report
async function delayedBoom(): Promise<void> {
	await sleepAsync(20);
	throw new Error("delayed-orphan-boom");
}
delayedBoom();
