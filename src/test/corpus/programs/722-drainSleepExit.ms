// @stdout: after-sleep-ran
// @exit: 0
async function work(): Promise<void> {
	await sleepAsync(30);
	console.log("after-sleep-ran");
}
work();
