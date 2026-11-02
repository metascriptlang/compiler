// @stdout: field parent parent 8 deep
struct TextBox { text: string; }
struct Plain { n: int32; }

async function deeper(): Promise<string> {
	let local = "deep";
	const localPointer = local as Ptr<string>;
	return await spawn(() => `${localPointer[]}`);
}

async function run(): Promise<void> {
	let box: TextBox = { text: "field" };
	const fieldPointer = box.text as Ptr<string>;
	const field = await spawn(() => fieldPointer);
	let text = "parent";
	const textPointer = text as Ptr<string>;
	const returned = await spawn(() => textPointer);
	const read = await spawn(() => `${textPointer[]}`);
	let plain: Plain = { n: 8 };
	const plainPointer = plain as Ptr<Plain>;
	const plainRead = await spawn(() => plainPointer[].n);
	const nested = await deeper();
	console.log(`${field[]} ${returned[]} ${read} ${plainRead} ${nested}`);
}
await run();
