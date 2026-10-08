// @stdout: 1.5 4 1 7 5|9
// note: `readonly` on a struct or interface field is a modifier, as on a class member: the
// literal sets the field and a write through the type is refused. It used to parse as a field
// named `readonly`, which left the real field untyped and crashed codegen.
interface N { readonly x: float32; y: int32; }
struct P { readonly id: int32; private readonly tag: int32; v: int32; }
function make(): N { return { x: 1.0, y: 2 }; }
const n: N = { x: 1.5, y: 3 };
let p: P = { id: 7, tag: 1, v: 0 };
p.v = 5;
n.y = 4;
const out: string[] = [`${n.x} ${n.y} ${make().x} ${p.id} ${p.v}`];
p = { id: 9, tag: 2, v: 6 };
out.push(`${p.id}`);
console.log(out.join("|"));
