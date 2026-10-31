interface Item {
	n: int32;
	tag: string;
}

type ItemResult = Item | string;

struct Value {
	n: int32;
}

const asserted = (tag: string) => ({ n: 1, tag } as Item);
const nested = (tag: string) => (({ n: 2, tag } as Item) as Item);
const field = () => ({ n: 3, tag: "field" } as Item).n;
const union = (): ItemResult => ({ n: 4, tag: "union" });
const first = asserted("ok");
const second = nested("nested");
const item = union();
let unionText = "wrong";
if (typeof item != "string") {
	unionText = `${item.n} ${item.tag}`;
}

let state: Value = { n: 5 };
const read = () => state;
let copy = read();
copy.n = 9;
const result = `${first.n} ${first.tag}|${second.n} ${second.tag}|` +
	`${field()}|${unionText}|${state.n} ${copy.n}`;
if (result != "1 ok|2 nested|3|4 union|5 9") {
	throw new Error("object arrow expression or value result changed");
}
console.log(result);
