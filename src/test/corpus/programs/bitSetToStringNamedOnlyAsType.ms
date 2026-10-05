// @stdout: {M0, M3} {M1, M2}
// @xfail(js): BitSet toString reaches toItems, whose `sizeof(BitSet<E>) * 8` reaches the JS source on this base (std fix 3746aa1b6, wt/fix-wave6-corpus)
// @xfail(esm): as js
// @xfail(raiser): Raiser prints an enum as its number (card 2026-09-25-raiser-enum-to-string-prints-the-number)

enum M { M0, M1, M2, M3, M4, M5, M6, M7 }
struct Holder { mask: BitSet<M>; }

const s = (9 as uint8) as BitSet<M>;
const h: Holder = { mask: (6 as uint8) as BitSet<M> };
console.log(`${s.toString()} ${h.mask.toString()}`);
