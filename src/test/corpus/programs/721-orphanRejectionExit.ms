// @exit: 1
// @skip-js: node prints its own unhandled-rejection report; exit code matches but the text differs
async function boom(): Promise<void> {
	throw new Error("orphan-boom");
}
boom();
console.log("top-end");
