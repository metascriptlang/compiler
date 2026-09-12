// Parity program — a bare member joins a `BitSet<E>` from either side of `|`,
// `&` and `^`, and two sets over the same enum compare by their bits.
//
// @stdout: true,true,true,false|true,true,false,true|true,false
// @exit: 0

export enum E { A, B, C, D }

const s: BitSet<E> = E.A | E.C;
const left = E.B | s;
const right = s | E.B;
const both = E.D | s | E.B;
const meet = E.C & s;
const flip = E.A ^ s;
const same: BitSet<E> = E.C | E.A;
const other: BitSet<E> = E.C | E.B;

console.log(left.has(E.B) + "," + right.has(E.B) + "," + both.has(E.D) + "," + left.has(E.D) + "|" + meet.has(E.C) + "," + both.has(E.B) + "," + flip.has(E.A) + "," + flip.has(E.C) + "|" + (s == same) + "," + (s == other));
