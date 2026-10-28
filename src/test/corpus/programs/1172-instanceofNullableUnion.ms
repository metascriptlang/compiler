// @stdout: number=row,other,other string=row,other,other field=row,other,other sub=row narrowed=7,-,-

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class SubRow extends Row {
	constructor(value: int32) { super(value); }
}

class Holder {
	v: number | Row | null;
	constructor(v: number | Row | null) { this.v = v; }
}

function mkNumber(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function mkString(k: int32): string | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return "s";
}

function label(isRow: boolean): string {
	return isRow ? "row" : "other";
}

function readNarrowed(c: number | Row | null): string {
	if (c instanceof Row) return c.value.toString();
	return "-";
}

const numbers: string[] = [];
const strings: string[] = [];
const fields: string[] = [];
const narrowed: string[] = [];
for (let k: int32 = 0; k < 3; k += 1) {
	const c: number | Row | null = mkNumber(k);
	numbers.push(label(c instanceof Row));
	const s: string | Row | null = mkString(k);
	strings.push(label(s instanceof Row));
	const h = new Holder(mkNumber(k));
	fields.push(label(h.v instanceof Row));
	narrowed.push(readNarrowed(mkNumber(k)));
}
const sub: number | Row | null = new SubRow(3);
console.log(`number=${numbers.join(",")} string=${strings.join(",")} field=${fields.join(",")} sub=${label(sub instanceof Row)} narrowed=${narrowed.join(",")}`);
