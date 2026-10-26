// @stdout: then1
// @stdout: round0
// @stdout: then2
// @stdout: round1
// @stdout: then3
// @stdout: caught x
// note: An await of an already settled future resumes behind the callbacks queued before it, resolved or rejected alike.

async function main(): Promise<void> {
	Promise.resolve(0).then((t: int32): void => { console.log("then1"); });
	await Promise.resolve(0);
	console.log("round0");
	Promise.resolve(0).then((t: int32): void => { console.log("then2"); });
	await Promise.resolve(0);
	console.log("round1");
	const failed: Promise<int32> = Promise.reject(new Error("x"));
	Promise.resolve(0).then((t: int32): void => { console.log("then3"); });
	try {
		await failed;
	} catch (e) {
		console.log(`caught ${(e as Error).message}`);
	}
}
main();
