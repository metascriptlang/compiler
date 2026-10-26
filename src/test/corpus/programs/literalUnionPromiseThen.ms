// @stdout: letter b
// @stdout: one a
// @stdout: num 2
// @stdout: half 1.5
// @stdout: param ab
// @stdout: spawned b 2
// note: a promise whose value is a literal type keeps that value at the literal's base type from the async return, through .then and a spawn, to a callback whose parameter is the literal union, for string unions, a single string literal, and integer and fractional unions.

type Letter = "a" | "b";

async function letter(big: boolean): Promise<Letter> { return big ? "b" : "a"; }
async function one(): Promise<"a"> { return "a"; }
async function num(big: boolean): Promise<1 | 2> { return big ? 2 : 1; }
async function half(big: boolean): Promise<0.5 | 1.5> { return big ? 1.5 : 0.5; }

function pickLetter(big: boolean): Letter { return big ? "b" : "a"; }
function pickNum(big: boolean): 1 | 2 { return big ? 2 : 1; }

function join(x: Letter, y: Letter): string { return x + y; }

await letter(true).then((v) => { console.log("letter", v); });
await one().then((v) => { console.log("one", v); });
await num(true).then((v) => { console.log("num", v + 0); });
await half(true).then((v) => { console.log("half", v + 0); });
console.log("param", join(await letter(false), await letter(true)));

async function spawned(): Promise<void> {
	const s = await spawn(() => pickLetter(true));
	const k = await spawn(() => pickNum(true));
	console.log("spawned", s, k + 0);
}
await spawned();
