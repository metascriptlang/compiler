// @stdout: 2 3|12 30|ns 2 3|ab+1 local 7
// note: two modules each export a type named Scene with a static `create` and a routine `add`
// taking it by `ref`. A static extension binds to the type its `this typeof` names, not to the
// name, and routines of one name imported from several modules form one overload set with a
// local routine of that name. Both used to bind the first module's symbol.
import { Scene as Scene2D, add } from "./twoD";
import { Scene as Scene3D, add } from "./threeD";
import { add } from "./text";
import * as v2 from "./twoD";
import * as v3 from "./threeD";

function add(n: int32): string { return `local ${n}`; }

const out: string[] = [];

let a: Scene2D = Scene2D.create();
let b: Scene3D = Scene3D.create();
out.push(`${a.nodes} ${b.nodes}`);
add(a, 10);
add(b, 10);
out.push(`${a.nodes} ${b.nodes}`);
const c: v2.Scene = v2.Scene.create();
const d: v3.Scene = v3.Scene.create();
out.push(`ns ${c.nodes} ${d.nodes}`);
out.push(`${add("ab", 1)} ${add(7)}`);
console.log(out.join("|"));
