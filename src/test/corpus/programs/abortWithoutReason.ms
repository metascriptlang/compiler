// @stdout: true AbortError: This operation was aborted | true AbortError: This operation was aborted | stop | false
const controller = new AbortController();
controller.abort();
const signal = AbortSignal.abort();
const first = new AbortController();
first.abort("stop");
first.abort();
const idle = new AbortController();
console.log([
	`${controller.signal.aborted} ${controller.signal.reason}`,
	`${signal.aborted} ${signal.reason}`,
	first.signal.reason,
	`${idle.signal.aborted}`,
].join(" | "));
