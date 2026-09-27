// GUARD-BALANCE int32_tArrayRefCell
// GUARD-BALANCE msStringArrayRefCell
// GUARD-BALANCE msUint8ArrayRefCell
// GUARD-JS

type ItemId = distinct int32;
type Label = distinct string;

function makeIds(): ItemId[] {
	const ids: ItemId[] = [];
	for (let i: int32 = 1; i <= 64; i += 1) ids.push(i as ItemId);
	return ids;
}

function makeLabels(): Label[] {
	const labels: Label[] = [];
	for (let i: int32 = 0; i < 8; i += 1) labels.push(("label".repeat(40) + i.toString()) as Label);
	return labels;
}

function round(): string {
	const ids = makeIds();
	const labels = makeLabels();
	let sum: int32 = 0;
	let bytes: int32 = 0;
	for (const id of ids) sum += id as int32;
	for (const label of labels) bytes += (label as string).length as int32;
	return `${sum}:${bytes}:${(labels[7] as string).slice(200, 201)}`;
}

let failures: int32 = 0;
let result = "";
for (let i: int32 = 0; i < 128; i += 1) {
	result = round();
	if (result != "2080:1608:7") failures += 1;
}
console.log(`distinct elements ${result} failures=${failures}`);

if (failures != 0) { throw new Error("distinct element values were not preserved"); }
console.log("GUARD-OK");
