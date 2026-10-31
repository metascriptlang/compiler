// @stdout: 3
// @stdout: 3
// @stdout: 4
// @stdout: 2 5

struct Plain { v: void; n: int32; }

function bump(p: Plain): int32 { return p.n + 1; }

let p: Plain = { v: null, n: 3 };
console.log(p.n);
p.v = null;
const read = p.v;
console.log(p.n);
console.log(bump(p));
const list: Plain[] = [p, { v: null, n: 5 }];
console.log(String(list.length) + " " + String(list[1].n));
