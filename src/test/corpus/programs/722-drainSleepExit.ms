// @stdout: after-sleep-ran
// @exit: 0
// @skip-js: sleepAsync is not bound in the js prelude yet
async function work(): Promise<void> {
	await sleepAsync(30);
	console.log("after-sleep-ran");
}
work();
