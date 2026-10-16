async function tick(label: string): Promise<void> {
	await sleepAsync(0);
	console.log(label);
}

console.log("lazy start");
tick("timer in body");
await sleepAsync(5);
console.log("lazy end");
export const v: int32 = 7;
export let reads: int32 = v + 1;
