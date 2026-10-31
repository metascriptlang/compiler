// @stdout: 5,-1
// @stdout: 9007199254740995,5,101,100
// @stdout: 2.5,~,0
// @stdout: true,false,~
// @stdout: [hi ab],[hi ],[~],[hi é]
// @stdout: [],[~],[x]
// @stdout: 7/x|255/|200/-|255/-
// @stdout: 0,16777215,4294967295,~
// @stdout: -128,127,~
// @stdout: 9007199254740995,~
// @stdout: 7:a|~:|3:~
// @stdout: true/-5/9007199254740993|~/~/~|false/127/0
// @stdout: 102
import { orMinus, sumBig, halve, parity, greet, emptyOrNull, label, echoU32, echoSmall, bigAt, replay, replayBig, fold } from "./nullableScalarsWasm";

function showInt(v: int32 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showSmall(v: int8 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showUnsigned(v: uint32 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showBig(v: int64 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showNum(v: float64 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showFlag(v: boolean | null): string {
	if (v == null) { return "~"; }
	return v ? "true" : "false";
}

function showText(v: string | null): string {
	if (v == null) { return "~"; }
	return v;
}

console.log(`${orMinus(5)},${orMinus(null)}`);
console.log(`${sumBig(9007199254740993, 2)},${sumBig(null, 5)},${sumBig(1)},${sumBig(null)}`);
console.log(`${showNum(halve(5))},${showNum(halve(-1))},${showNum(halve(0))}`);
console.log(`${showFlag(parity(4))},${showFlag(parity(3))},${showFlag(parity(-2))}`);
console.log(`[${showText(greet("ab"))}],[${showText(greet(""))}],[${showText(greet(null))}],[${showText(greet("é"))}]`);
console.log(`[${showText(emptyOrNull(0))}],[${showText(emptyOrNull(-1))}],[${showText(emptyOrNull(1))}]`);
console.log([label(7, "x"), label(null, ""), label(200, null), label(null, null)].join("|"));
console.log(`${showUnsigned(echoU32(0))},${showUnsigned(echoU32(16777215))},${showUnsigned(echoU32(4294967295))},${showUnsigned(echoU32(null))}`);
const lo: int8 = -128;
console.log(`${showSmall(echoSmall(lo))},${showSmall(echoSmall(127))},${showSmall(echoSmall(null))}`);
console.log(`${showBig(bigAt(9007199254740993, 2))},${showBig(bigAt(9007199254740993, -1))}`);
const seen: string[] = [];
replay((n: int32 | null, s: string | null): void => { seen.push(`${showInt(n)}:${showText(s)}`); });
console.log(seen.join("|"));
const wide: string[] = [];
replayBig((f: boolean | null, s: int8 | null, b: int64 | null): void => { wide.push(`${showFlag(f)}/${showSmall(s)}/${showBig(b)}`); });
console.log(wide.join("|"));
console.log(`${fold((x: float64 | null): int32 => { if (x == null) { return 100; } return x > 1 ? 2 : 1; })}`);
