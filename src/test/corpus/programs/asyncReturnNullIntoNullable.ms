// @stdout: true true
// @stdout: true 4 s
async function find(hit: boolean): Promise<Vec<uint8> | null> {
	if (!hit) { return null; }
	const found: Vec<uint8> = [1];
	return found;
}
async function name(hit: boolean): Promise<string | null> {
	if (!hit) { return null; }
	return "x";
}
async function opt(n: int32): Promise<int32 | null> {
	if (n < 0) { return null; }
	return n;
}
async function strict(): Promise<string> { return "s"; }
const a = await find(false);
const b = await name(false);
console.log(a === null, b === null);
console.log(await opt(-1) === null, await opt(4), await strict());
