async function tick(): Promise<void> {
	await sleepAsync(0);
	console.log("tick done");
}

console.log("side body");
tick();
export const v: int32 = 7;
