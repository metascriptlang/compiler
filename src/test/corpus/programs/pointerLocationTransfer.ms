// @stdout: location-transfer 42 parent field true | 42 parent field global | 41
struct TextBox { text: string; }
struct Plain { n: int32; }
let globalText = "global";
const globalPointer = globalText as Ptr<string>;

async function run(): Promise<void> {
	let values: int32[] = [31, 42];
	const elementPointer = values[1..2] as Span<int32> as Ptr<int32>;
	let text = "parent";
	const registerPointer = text as Ptr<string>;
	const registerAlias = text as Ptr<string>;
	let box: TextBox = { text: "field" };
	const fieldPointer = box.text as Ptr<string>;
	const read = await spawn(() => `${elementPointer[]} ${registerPointer[]} ${fieldPointer[]} ${registerPointer == registerAlias}`);
	const elementResult = await spawn(() => elementPointer);
	const registerResult = await spawn(() => registerPointer);
	const fieldResult = await spawn(() => fieldPointer);
	const globalResult = await spawn(() => globalPointer);
	let plain: Plain = { n: 41 };
	const plainPointer = plain as Ptr<Plain>;
	const plainResult = await spawn(() => plainPointer[].n);
	console.log(`location-transfer ${read} | ${elementResult[]} ${registerResult[]} ${fieldResult[]} ${globalResult[]} | ${plainResult}`);
}
await run();
