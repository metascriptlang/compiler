import { compileToC } from "../helpers";

function bodyOf(code: string, fn: string): string {
	for (const line of code.split("\n")) {
		if (line.endsWith(" {") && line.indexOf(" " + fn + "__") >= 0) {
			const start = code.indexOf(line + "\n");
			return code.slice(start, code.indexOf("\n}", start));
		}
	}
	return "";
}

function count(text: string, token: string): int32 {
	return (text.split(token).length - 1) as int32;
}

const APPEND_THEN_READ = `
class Item { tag: string = ""; }
struct Big { item: Item; a: int64; b: int64; c: int64; }
const items: Item[] = [];
const bigs: Big[] = [];
function growItems(x: Item): int32 {
	items.push(new Item());
	return x.tag.length as int32;
}
function growBigs(x: Big): int32 {
	bigs.push({ item: new Item(), a: 0, b: 0, c: 0 });
	return x.item.tag.length as int32;
}
function readItem(i: int32): int32 { return growItems(items[i]); }
function readBig(i: int32): int32 { return growBigs(bigs[i]); }
console.log(readItem(0) + readBig(0));
`;

test "an append moves no reference a callee was handed by value, so the element is not pinned" {
	const result = compileToC(APPEND_THEN_READ);
	assert result.ok, result.error;
	const body = bodyOf(result.value, "readItem");
	assert body != "" && count(body, "msIncref(") == 0, body;
}

test "an append moves the struct a callee was handed by address, so the element stays pinned" {
	const result = compileToC(APPEND_THEN_READ);
	assert result.ok, result.error;
	const body = bodyOf(result.value, "readBig");
	assert count(body, "Copy(") == 1, body;
}
