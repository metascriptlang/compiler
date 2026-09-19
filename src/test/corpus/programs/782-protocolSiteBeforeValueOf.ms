// Parity program — a type that declares `valueOf` beside a protocol of its own
// for one position is read through that protocol there, and through `valueOf`
// only where it has none: a converter for a `string` slot and `as string`,
// `toItems` for `for..of`, `valueOf` for an `int32` slot (no converter), for an
// operand, and first for `+` with a string, as in JS.
//
// @stdout: slot S|as S|fallback 100|items 5,6|operand 101|concat v=100
// @exit: 0

interface Box { n: int32; }

function valueOf(this b: Box): int32 { return 100; }
converter boxToText(b: Box): string { return "S"; }
function toItems(this b: Box): int32[] { return [5, 6]; }

const b: Box = { n: 1 };
const s: string = b;
const viaAs = b as string;
const plain: int32 = b;
let items = "";
for (const x of b) {
	items = items == "" ? x.toString() : items + "," + x.toString();
}
const concat = "v=" + b;
console.log(`slot ${s}|as ${viaAs}|fallback ${plain}|items ${items}|operand ${b + 1}|concat ${concat}`);
