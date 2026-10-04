// @stdout: 1,2,3|ab,c||1,2,,3|a,,b|label:x,label:y
class Label {
	text: string;
	constructor(text: string) { this.text = text; }
	toString(): string { return "label:" + this.text; }
}
const numbers: int32[] = [1, 2, 3];
const words: string[] = ["a" + "b", "c"];
const empty: string[] = [];
const nested: int32[][] = [[1, 2], [], [3]];
const absent: (string | null)[] = ["a", null, "b"];
const labels: Label[] = [new Label("x"), new Label("y")];
console.log(`${numbers.toString()}|${words.toString()}|${empty.toString()}|${nested.toString()}|${absent.toString()}|${labels.toString()}`);
