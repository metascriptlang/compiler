// Parity program — a runtime converter reads an operand against the static
// type of the other side: arithmetic on either side, a compound assignment, a
// comparison, an equality and a string concatenation; a condition keeps the
// value as it is even when a converter to boolean exists.
//
// @stdout: add 45|radd 46|mul 88|acc 44|gt true|eq true|text n=box#44|cond yes
// @exit: 0

interface Box { n: int32; }

converter boxToInt(b: Box): int32 { return b.n; }
converter boxToText(b: Box): string { return "box#" + String(b.n); }
converter boxToFlag(b: Box): boolean { return false; }

const box: Box = { n: 44 };
const add = box + 1;
const radd = 2 + box;
const mul = box * 2;
let acc: int32 = 0;
acc += box;
const gt = box > 40;
const eq = box == 44;
const text = "n=" + box;
const cond = box ? "yes" : "no";

console.log(`add ${add}|radd ${radd}|mul ${mul}|acc ${acc}|gt ${gt}|eq ${eq}|text ${text}|cond ${cond}`);
