// @stdout: {M0, M3} {M1, M2}

enum M { M0, M1, M2, M3, M4, M5, M6, M7 }
struct Holder { mask: BitSet<M>; }

const s = (9 as uint8) as BitSet<M>;
const h: Holder = { mask: (6 as uint8) as BitSet<M> };
console.log(`${s.toString()} ${h.mask.toString()}`);
