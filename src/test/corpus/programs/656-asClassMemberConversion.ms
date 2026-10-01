// @stdout: class-as carried=row:7,null,row:7 plain=row:7,row:7 ret=row:7,null arg=row:7 field=row:7,null two=other:5,null narrowed=row:7 loop=row:7:3

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Other { tag: int32 = 5; }

class Slot { row: Row | null = null; }

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function plainOf(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

function twoOf(k: int32): Row | Other | null {
	if (k == 0) return new Other();
	if (k == 1) return null;
	return new Row(7);
}

function show(r: Row | null): string {
	return r == null ? "null" : `row:${r.value}`;
}

function showOther(o: Other | null): string {
	return o == null ? "null" : `other:${o.tag}`;
}

function returnsCarried(k: int32): Row | null {
	const a: number | Row | null = carriedOf(k);
	return a as Row | null;
}

function takesCarried(a: number | Row | null): string {
	return show(a as Row | null);
}

function narrowed(a: number | Row | null): string {
	if (a !== null) return show(a as Row | null);
	return "null";
}

function carried(): string {
	const a: number | Row | null = carriedOf(0);
	const b: number | Row | null = carriedOf(1);
	const c: number | Row | null = carriedOf(0);
	const x: Row | null = a as Row | null;
	const y: Row | null = b as Row | null;
	const z: Row = c as Row;
	return [show(x), show(y), show(z)].join(",");
}

function plain(): string {
	const a: number | Row = plainOf(0);
	const b: number | Row = plainOf(0);
	const x: Row = a as Row;
	const y: Row | null = b as Row | null;
	return [show(x), show(y)].join(",");
}

function field(): string {
	const holder = new Slot();
	const a: number | Row | null = carriedOf(0);
	holder.row = a as Row | null;
	const first = show(holder.row);
	const b: number | Row | null = carriedOf(1);
	holder.row = b as Row | null;
	return first + "," + show(holder.row);
}

function two(): string {
	const a: Row | Other | null = twoOf(0);
	const b: Row | Other | null = twoOf(1);
	return showOther(a as Other | null) + "," + showOther(b as Other | null);
}

function loop(): string {
	let seen = 0 as int32;
	for (let i = 0; i < 3; i += 1) {
		const a: number | Row | null = carriedOf(0);
		const r: Row | null = a as Row | null;
		if (r != null) seen += 1;
	}
	return `${show(returnsCarried(0))}:${seen}`;
}

function main(): void {
	console.log("class-as"
		+ " carried=" + carried()
		+ " plain=" + plain()
		+ " ret=" + show(returnsCarried(0)) + "," + show(returnsCarried(1))
		+ " arg=" + takesCarried(carriedOf(0))
		+ " field=" + field()
		+ " two=" + two()
		+ " narrowed=" + narrowed(carriedOf(0))
		+ " loop=" + loop());
}
main();
