// @stdout: true false false true true|true false true|true false true|false false|true true false true true|true true|true true true false true|true true false false false|ab three other|true false true|true true true false|true true 1 false|false true false true true
// note: `==`, `!=` and a switch case between a union and a value of one of its members, or between two unions, compare the member each holds: equal strings are equal, floats differ by value, a string never equals a number. A member operand is taken into the union first. Same output on C, JS and the Raiser.
function text(s: string): string | number { return s + "b"; }
function real(n: number): string | number { return n * 1.5; }
function whole(n: int32): string | int32 { return n; }
function viaClosure(u: string | number, v: string | number): boolean {
	const test = (): boolean => u == v || u == "ab";
	return test();
}
class Holder {
	held: string | number;
	constructor(held: string | number) { this.held = held; }
	sameAs(other: string | number): boolean {
		return this.held == other;
	}
}
const out: string[] = [];
const a = text("a");
const b = text("a");
const c = text("x");
out.push(`${a == b} ${a == c} ${a != b} ${a != c} ${a === b}`);
const x = real(2);
out.push(`${x == real(2)} ${x == real(3)} ${x != real(3)}`);
out.push(`${whole(3) == whole(3)} ${whole(3) == whole(4)} ${whole(3) != whole(4)}`);
out.push(`${a == real(2)} ${real(0) == text("")}`);
const s: string = "ab";
const n: number = 3;
out.push(`${a == s} ${s == a} ${text("") == s} ${real(2) == n} ${n == real(2)}`);
if (typeof a === "string") out.push(`${a == b} ${a == "ab"}`);
out.push(`${a == "ab"} ${"ab" == a} ${real(2) == 3} ${real(2) == 4} ${3 == real(2)}`);
const arr: (string | number)[] = ["ab", 3];
out.push(`${arr[1] == 3} ${arr[0] == a} ${arr[0] == "xy"} ${arr[1] != 3} ${arr[0] == arr[1]}`);
const pick = (u: string | number): string => {
	switch (u) {
		case "ab": return "ab";
		case 3: return "three";
		default: return "other";
	}
};
out.push(`${pick(a)} ${pick(arr[1])} ${pick(c)}`);
out.push(`${new Holder(text("a")).sameAs(text("a"))} ${new Holder(text("a")).sameAs(text("x"))} ${new Holder(3).sameAs(real(2))}`);
out.push(`${viaClosure(text("a"), text("a"))} ${viaClosure(text("x"), text("x"))} ${viaClosure(text("a"), text("x"))} ${viaClosure(real(2), real(3))}`);
const wide: (string | number)[] = ["ab", 3, 4.5];
out.push(`${wide.includes(text("a"))} ${wide.includes(4.5)} ${wide.indexOf(3)} ${wide.includes(7)}`);
const p: number | null = 2.5;
const q: number | null = 3.5;
const r: number | null = null;
out.push(`${p == q} ${p != q} ${p == r} ${r == null} ${p == 2.5}`);
console.log(out.join("|"));
