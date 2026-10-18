// @stdout: 0 10 NaN null | one t many | 0 5 end s | 0 7 null late w
// note: a short circuit whose right side the compiler turns into statements (a match, an await, a self tail call) tests its left side by TS truthiness: 0, NaN, "" and null stop `&&` and pass `||`. C applied `!` to the nullable left side and died at the C compiler; the Raiser read every float and string left side as false.

function num(v: number, on: boolean): number | null { return on ? v : null; }
function text(v: string, on: boolean): string | null { return on ? v : null; }

function guarded(a: number | null, k: int32): string {
	const r = a && match (k) { 1 => 10, _ => 20 };
	return r === null ? "null" : String(r);
}

function guardedText(a: string | null, k: int32): string {
	const r = a || match (k) { 1 => "one", _ => "many" };
	return r === null ? "null" : r;
}

function tail(n: number | null, k: int32): number | null {
	if (k == 0) { return n; }
	return n && tail(n, k - 1);
}

function tailOr(s: string, k: int32): string {
	if (k == 0) { return "end"; }
	return s || tailOr(s, k - 1);
}

async function later(v: number): Promise<number> { return v; }
async function laterText(v: string): Promise<string> { return v; }
async function awaited(a: number | null): Promise<string> {
	const r = a && await later(7);
	return r === null ? "null" : String(r);
}
async function awaitedText(a: string | null): Promise<string> {
	const r = a || await laterText("late");
	return r === null ? "null" : r;
}

const parts: string[] = [];
parts.push([guarded(num(0, true), 1), guarded(num(2, true), 1), guarded(num(NaN, true), 2), guarded(num(0, false), 2)].join(" "));
parts.push([guardedText(text("", true), 1), guardedText(text("t", true), 2), guardedText(text("", false), 2)].join(" "));
const t0 = tail(num(0, true), 3);
const t5 = tail(num(5, true), 3);
parts.push(`${t0 === null ? "null" : String(t0)} ${t5 === null ? "null" : String(t5)} ${tailOr("", 2)} ${tailOr("s", 2)}`);
async function main(): Promise<void> {
	parts.push([await awaited(num(0, true)), await awaited(num(3, true)), await awaited(num(1, false)), await awaitedText(text("", true)), await awaitedText(text("w", true))].join(" "));
	console.log(parts.join(" | "));
}
main();
