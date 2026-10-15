// @stdout: global 0 0, sized 0 0, emptied 0 0, tail 0 0, text 0, full 5 2
// @exit: 0

type Laid = { x: float32 };

function total(items: Readonly<Span<Laid>>): string {
	let sum: float32 = 0;
	for (let i = 0; i < (items.length as int32); i++) sum = sum + items[i].x;
	return `${sum} ${items.length}`;
}

function sumInts(items: Readonly<Span<int32>>): string {
	let sum: int32 = 0;
	for (let i = 0; i < (items.length as int32); i++) sum = sum + items[i];
	return `${sum} ${items.length}`;
}

function countChars(items: Readonly<Span<char>>): string {
	return `${items.length}`;
}

const glyphs: Laid[] = [];

function locals(parts: string[]): void {
	const sized = new Array<int32>(0);
	parts.push(`sized ${sumInts(sized[0..(sized.length as int32)])}`);

	const emptied: int32[] = [];
	emptied.push(4);
	emptied.pop();
	parts.push(`emptied ${sumInts(emptied[0..(emptied.length as int32)])}`);

	const values: int32[] = [1, 2, 3];
	parts.push(`tail ${sumInts(values[3..3])}`);

	const text = "";
	parts.push(`text ${countChars(text[0..0])}`);

	parts.push(`full ${sumInts(values[1..3])}`);
}

const parts: string[] = [];
parts.push(`global ${total(glyphs[0..(glyphs.length as int32)])}`);
locals(parts);
console.log(parts.join(", "));
