// @stdout: row:7 9|row:7 row:8|k3 k3|row:7,row:7
// note: `u as Row` out of a `number | Row | null` reads the member in place, so the local it
// initializes or is assigned to holds its own copy, released once beside the union.
class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function textOf(k: int32): number | string | null {
	if (k == 0) return "k" + String(k + 3);
	return null;
}

function initFromMember(): string {
	const c: number | Row | null = carriedOf(0);
	const z: Row = c as Row;
	const n: number | Row | null = carriedOf(2);
	return `row:${z.value} ${n as number}`;
}

function assignFromMember(): string {
	const c: number | Row | null = carriedOf(0);
	let z: Row = new Row(8);
	const first = `row:${z.value}`;
	z = c as Row;
	return `row:${z.value} ${first}`;
}

function stringMember(): string {
	const t: number | string | null = textOf(0);
	const s: string = t as string;
	return `${s} ${t as string}`;
}

function afterwards(): string {
	const rows: Row[] = [new Row(7), new Row(7)];
	return rows.map((r: Row): string => `row:${r.value}`).join(",");
}

console.log([initFromMember(), assignFromMember(), stringMember(), afterwards()].join("|"));
