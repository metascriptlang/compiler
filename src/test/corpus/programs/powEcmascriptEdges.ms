// @stdout: NaN/NaN NaN/NaN NaN/NaN 1/1 1/1 1/1 1/1 1/1 1/1 1/1 1/1 | NaN/NaN NaN/NaN NaN/NaN 1/1 1/1 -1/-1 -1/-1 1/1 -1/-1 NaN/NaN -1/-1 | NaN/NaN 0/0 Infinity/Infinity 1/1 1/1 0/0 Infinity/Infinity 0/0 0/0 0/0 Infinity/Infinity | NaN/NaN 0/0 Infinity/Infinity 1/1 1/1 -0/-0 -Infinity/-Infinity 0/0 -0/-0 0/0 -Infinity/-Infinity | NaN/NaN NaN/NaN NaN/NaN 1/1 1/1 NaN/NaN NaN/NaN NaN/NaN NaN/NaN NaN/NaN NaN/NaN | NaN/NaN Infinity/Infinity 0/0 1/1 1/1 Infinity/Infinity 0/0 Infinity/Infinity Infinity/Infinity Infinity/Infinity 0/0 | NaN/NaN Infinity/Infinity 0/0 1/1 1/1 -Infinity/-Infinity -0/-0 Infinity/Infinity -Infinity/-Infinity Infinity/Infinity -0/-0 | NaN/NaN Infinity/Infinity 0/0 1/1 1/1 2/2 0.5/0.5 4/4 8/8 1.4142135623730951/1.4142135623730951 0.125/0.125 | NaN/NaN Infinity/Infinity 0/0 1/1 1/1 -2/-2 -0.5/-0.5 4/4 -8/-8 NaN/NaN -0.125/-0.125 | NaN/NaN 0/0 Infinity/Infinity 1/1 1/1 0.5/0.5 2/2 0.25/0.25 0.125/0.125 0.7071067811865476/0.7071067811865476 8/8 | NaN/NaN 0/0 Infinity/Infinity 1/1 1/1 -0.5/-0.5 -2/-2 0.25/0.25 -0.125/-0.125 NaN/NaN -8/-8 | NaN NaN NaN NaN NaN NaN | NaN NaN NaN 1024 | NaN NaN 1.4142135623730951 0.01
// note: `**` and Math.pow follow ECMAScript Number::exponentiate on every backend: a NaN exponent gives NaN, and a 1 or -1 base with an infinite exponent gives NaN, for variables, literals, a float32 power and a call. C called its own pow, which answers 1 for those, as did the Raiser through the compiler's Math.pow; an integer power is unchanged.

function show(x: number): string {
	if (x != x) return "NaN";
	if (x == 0) return 1 / x < 0 ? "-0" : "0";
	return `${x}`;
}
const bases: number[] = [1, -1, 0, -0, NaN, Infinity, -Infinity, 2, -2, 0.5, -0.5];
const exps: number[] = [NaN, Infinity, -Infinity, 0, -0, 1, -1, 2, 3, 0.5, -3];
const rows: string[] = [];
for (const b of bases) {
	const cells: string[] = [];
	for (const e of exps) cells.push(show(b ** e) + "/" + show(Math.pow(b, e)));
	rows.push(cells.join(" "));
}
const literal = [show(1 ** NaN), show((-1) ** Infinity), show(1 ** Infinity), show(1 ** -Infinity), show(Math.pow(1, NaN)), show(Math.pow(-1, -Infinity))].join(" ");
let acc: number = 1;
acc = acc ** NaN;
let acc2: number = -1;
acc2 = acc2 ** Infinity;
const one32: float32 = 1;
const inf32: float32 = Infinity as float32;
const p32: float32 = (one32 ** inf32) as float32;
const i: int32 = 2;
function power(b: number, e: number): number { return b ** e; }
const late = [show(power(1, NaN)), show(power(-1, -Infinity)), show(power(2, 0.5)), show(power(10, -2))].join(" ");
console.log(rows.join(" | ") + " | " + literal + " | " + show(acc) + " " + show(acc2) + " " + show(p32) + " " + `${i ** 10}` + " | " + late);
