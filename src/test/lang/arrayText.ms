class TextLabel {
	text: string;
	constructor(text: string) { this.text = text; }
	toString(): string { return "label:" + this.text; }
}

test "array text: primitive elements use comma separators and empty arrays have empty text" {
	const numbers: int32[] = [1, 2, 3];
	const words: string[] = ["a" + "b", "c"];
	const empty: string[] = [];
	assert numbers.toString() == "1,2,3";
	assert words.toString() == "ab,c";
	assert empty.toString() == "";
}

test "array text: nested arrays and absent elements preserve their empty fields" {
	const nested: int32[][] = [[1, 2], [], [3]];
	const absent: (string | null)[] = ["a", null, "b"];
	assert nested.toString() == "1,2,,3";
	assert absent.toString() == "a,,b";
}

test "array text: declared element methods determine their text" {
	const labels: TextLabel[] = [new TextLabel("x"), new TextLabel("y")];
	assert labels.toString() == "label:x,label:y";
}

test "array text: String and interpolation share the declared element conversion" {
	const numbers: int32[] = [1, 2];
	const nested: int32[][] = [[3], [], [4]];
	const absent: (string | null)[] = ["a", null, "b"];
	const labels: TextLabel[] = [new TextLabel("x"), new TextLabel("y")];
	assert String(numbers) == "1,2" && `${numbers}` == "1,2";
	assert String(nested) == "3,,4" && `${nested}` == "3,,4";
	assert String(absent) == "a,,b" && `${absent}` == "a,,b";
	assert String(labels) == "label:x,label:y" && `${labels}` == "label:x,label:y";
}
