interface CorpusBindingSource { x: string; y: int32; }
function readQuotedPattern({ "x": text, "y": count }: CorpusBindingSource): int32 {
	return text.length + count;
}

let calls: int32 = 0;
const make = () => {
	calls += 1;
	return { "data-probe": 7, a_b: 4, other: 5 };
};
const { "data-probe": first = 99, ...rest } = make();
const source = { "a\"b": 1, "slash\\path": 2, "đèn": 3, "a:b;c,d": 4, "": 5 };
const { "a\"b": quote, "slash\\path": slash, "đèn": unicode, "a:b;c,d": punctuation, "": empty } = source;
const values: CorpusBindingSource[] = [{ x: "a", y: 2 }, { x: "bb", y: 3 }];
let total: int32 = 0;
for (const { "x": text, "y": count } of values) {
	total += text.length + count;
}
const parameter = readQuotedPattern({ x: "yes", y: 7 });
const result = `${first} ${rest.a_b} ${rest.other}|${quote} ${slash} ${unicode} ${punctuation} ${empty}|${calls}|${parameter} ${total}`;
if (result != "7 4 5|1 2 3 4 5|1|10 8") {
	throw new Error("quoted object binding changed key identity, rest, or source evaluation");
}
console.log(result);
