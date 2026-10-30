// @stdout: struct 100C|at 100|100C|100C class K7|at 7|K7 valueOf-only 5|at 5|5
// @exit: 0
// note: a template reads its interpolation with the string hint (toString first, valueOf when there is none); `+` reads valueOf first.

struct Temp { c: int32; }
function toString(this t: Temp): string {
	return `${t.c}C`;
}
function valueOf(this t: Temp): int32 {
	return t.c;
}

struct OnlyV { c: int32; }
function valueOf(this t: OnlyV): int32 {
	return t.c;
}

class Gauge {
	c: int32 = 7;
	toString(): string {
		return "K" + this.c.toString();
	}
	valueOf(): int32 {
		return this.c;
	}
}

const x: Temp = { c: 100 };
const o: OnlyV = { c: 5 };
const g = new Gauge();
const parts = [
	`struct ${x}|${"at " + x}|${x.toString()}|${String(x)}`,
	`class ${g}|${"at " + g}|${String(g)}`,
	`valueOf-only ${o}|${"at " + o}|${String(o)}`,
];
console.log(parts.join(" "));
