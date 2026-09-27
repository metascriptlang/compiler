// @stdout: spawn contexts 9 5 1
// @serial

class Data { n: int32 = 7; }

async function moved(): Promise<int32> {
	const data = new Data();
	const handle = spawn(() => { data.n = data.n + 2; return data.n; }, { move: [data] });
	return await handle;
}
async function one(): Promise<int32> { return 1; }
async function inThunk(): Promise<int32> {
	const handle = spawn(() => { return await one(); });
	return await handle;
}
async function borrowed(): Promise<int32> {
	const value: int32 = 4;
	const handle = spawn(() => value + 1);
	return await handle;
}
const owned = await moved();
const read = await borrowed();
const nested = await inThunk();
console.log(`spawn contexts ${owned} ${read} ${nested}`);
