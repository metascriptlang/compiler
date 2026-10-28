function describe(values: [string, boolean][]): string {
	const item = values[0];
	return `${item[0]}:${item[1]}`;
}

const pair: [string, boolean] = ["ready", true];
const values: [string, boolean][] = [pair];
const nested: [string, boolean][][] = [values];
const entry: { label: string; ready: boolean } = { label: "item", ready: false };
const objects: { label: string; ready: boolean }[] = [entry];
const result = `${describe(values)} nested=${nested[0][0][0]} ` +
	`object=${objects[0].label}:${objects[0].ready}`;
console.log(result);
if (result != "ready:true nested=ready object=item:false") {
	throw new Error("array type suffix changed an element");
}
