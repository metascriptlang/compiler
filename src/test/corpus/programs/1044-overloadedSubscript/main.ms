// @stdout: 100 102 104 | 43 | 6
// note: a user type with a `[]` / `[]=` extension is indexed through a call the checker binds to the extension of the receiver's own declaration. Three modules each declare a `Grid`; two give theirs a subscript extension (one with a setter) and one has none, so its `items[i]` stays a built-in array index.
import { Grid as GridA } from "./a";
import { Grid as GridB } from "./b";
import { makeItems } from "./c";

const a = new GridA();
const first = a[0];
a[1] = 1;
a[2] = 2;
const b = new GridB();
const c = makeItems();
console.log(`${first} ${a[1]} ${a[2]} | ${b[3]} | ${c.items[1]}`);
