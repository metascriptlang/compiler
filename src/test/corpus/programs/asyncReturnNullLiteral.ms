// @stdout: null a null null 4 null null

interface Item { name: string; }

async function find(name: string): Promise<Item | null> {
	if (name === "") { return null; }
	return { name };
}

async function nothing(): Promise<string | null> { return null; }

const arrowNum = async (n: int32): Promise<int32 | null> => {
	if (n < 0) { return null; }
	return n;
};

class Box {
	static async pick(n: int32): Promise<int32 | null> {
		if (n === 0) { return null; }
		return n + 4;
	}
	async maybe(n: int32): Promise<string | null> {
		await nothing();
		if (n === 0) { return null; }
		return "m";
	}
}

async function main(): Promise<void> {
	const missing = await find("");
	const found = await find("a");
	const parts: string[] = [];
	parts.push(missing === null ? "null" : "item");
	parts.push(found === null ? "null" : found.name);
	parts.push((await nothing()) === null ? "null" : "str");
	parts.push((await Box.pick(0)) === null ? "null" : "num");
	const v = await arrowNum(4);
	parts.push(v === null ? "null" : v.toString());
	parts.push((await arrowNum(-1)) === null ? "null" : "num");
	parts.push((await new Box().maybe(0)) === null ? "null" : "str");
	console.log(parts.join(" "));
}

main();
