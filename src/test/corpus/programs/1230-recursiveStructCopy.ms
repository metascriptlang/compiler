// @stdout: 1 0
// @stdout: 1 2 3 | 1 9 3
// @stdout: 1 2
// @stdout: 7 1
struct K { v: int32; kids: Vec<K>; }
struct A { v: int32; kids: A[]; }
class C { v: int32 = 0; kids: Vec<C> = []; }

const k: K = { v: 1, kids: [] };
const copy = k;
console.log(copy.v, copy.kids.length);

let tree: K = { v: 1, kids: [] };
tree.kids.push({ v: 2, kids: [] });
tree.kids[0].kids.push({ v: 3, kids: [] });
let twin = tree;
twin.kids[0].v = 9;
console.log(`${tree.v} ${tree.kids[0].v} ${tree.kids[0].kids[0].v} | ${twin.v} ${twin.kids[0].v} ${twin.kids[0].kids[0].v}`);

let arr: A = { v: 1, kids: [{ v: 2, kids: [] }] };
const arrCopy = arr;
console.log(arrCopy.v, arrCopy.kids[0].v);

const c = new C();
c.v = 7;
c.kids.push(new C());
const alias = c;
console.log(alias.v, alias.kids.length);
