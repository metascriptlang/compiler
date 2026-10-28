// @xfail(raiser): the Raiser VM grows through msGenericArraySetLen, which fills no default
// @stdout: b a b a a
// note: an array of a literal-union element type grows with the union's first member in the new slots, by `length =` and by setLength, on C, danger, JS and esm; an ordinary int32[] growing stays arrayLengthGrowZeroFill.
type F = "a" | "b";
struct S { f: F; n: int32; }
const g: S[] = [];
g.push({ f: "b", n: 1 });
g.length = 3;
const gf: F[] = ["b"];
gf.length = 3;
gf.setLength(4);
console.log(`${g[0].f} ${g[2].f} ${gf[0]} ${gf[2]} ${gf[3]}`);
