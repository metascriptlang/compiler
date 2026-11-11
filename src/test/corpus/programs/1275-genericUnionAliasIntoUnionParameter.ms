// @stdout: n5 t6 | p3 t7 | L1 T2 | n8 t9 | back n4 t5
// note: an instance of a generic union alias (`G<number>` for `type G<T> = T | Twig`) is the union it names, so it
// is passed where that union is the parameter and converted member by member, as a named union is; the C build
// passed the instance's own struct to the union's parameter unconverted, and a struct arm was refused outright.
class Twig { id: int32 = 0; }
class Leaf { id: int32 = 0; }
struct Pt { x: int32; y: int32; }
type G<T> = T | Twig;

function twig(id: int32): Twig { const t = new Twig(); t.id = id; return t; }
function leaf(id: int32): Leaf { const l = new Leaf(); l.id = id; return l; }

function num(v: number | Twig): string { return typeof v == "number" ? `n${v}` : `t${v.id}`; }
function pt(v: Pt | Twig): string { return v instanceof Twig ? `t${v.id}` : `p${(v as Pt).x}`; }
function cls(v: Leaf | Twig): string { return v instanceof Leaf ? `L${v.id}` : `T${v.id}`; }

function numArg(g: G<number>): string { return num(g); }
function ptArg(g: G<Pt>): string { return pt(g); }
function clsArg(g: G<Leaf>): string { return cls(g); }
function viaGeneric<T>(g: G<number>, extra: T): string { return num(g); }
function intoG(g: G<number>): string { return typeof g == "number" ? `n${g}` : `t${g.id}`; }
function back(v: number | Twig): string { return intoG(v); }

const p: Pt = { x: 3, y: 4 };
console.log(`${numArg(5)} ${numArg(twig(6))} | ${ptArg(p)} ${ptArg(twig(7))} | ${clsArg(leaf(1))} ${clsArg(twig(2))} | ${viaGeneric(8, "x")} ${viaGeneric(twig(9), "x")} | back ${back(4)} ${back(twig(5))}`);
