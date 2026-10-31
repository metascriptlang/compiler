// @stdout: log {A, B}
// @stdout: template {A, B}
// @stdout: concat {A, B}
// @stdout: string {A, B}
// @stdout: method {A, B}
// @stdout: empty {}
// @stdout: wide {A, I}
// @exit: 0
// note: a BitSet<E> in console.log, a template, `+` and String() reads its documented text `{A, B}`, the same as .toString(), on every backend; the representation word and `<BitSet>` were the two wrong forms.

enum F { A, B }
enum W { A, B, C, D, E, G, H, J, I }

const s: BitSet<F> = F.A | F.B;
const none = 0 as BitSet<F>;
const wide: BitSet<W> = W.A | W.I;

console.log("log", s);
console.log(`template ${s}`);
console.log("concat " + s);
console.log("string " + String(s));
console.log("method " + s.toString());
console.log(`empty ${none}`);
console.log(`wide ${wide}`);
