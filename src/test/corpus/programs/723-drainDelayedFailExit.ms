// @exit: 1
// @skip-js: node exits 1 like C but prints its own unhandled-rejection report, and parity compares merged stdout+stderr (sibling of 721)
async function delayedBoom(): Promise<void> {
	await sleepAsync(20);
	throw new Error("delayed-orphan-boom");
}
delayedBoom();
