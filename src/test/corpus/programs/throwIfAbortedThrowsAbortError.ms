// @stdout: idle passes | caught AbortError
const controller = new AbortController();
controller.signal.throwIfAborted();
const parts: string[] = ["idle passes"];
controller.abort();
try {
	controller.signal.throwIfAborted();
	parts.push("no throw");
} catch (e) {
	parts.push(`caught ${(e as Error).message}`);
}
console.log(parts.join(" | "));
