// @stdout: nested: 1 10|again: 2 10|whole: 4 10|end 9 5 5
struct In { x: int32; }
struct Out { p: In; n: int32; }
let o: Out = { p: { x: 1 }, n: 1 };
const seen: string[] = [];
function bumpO(): int32 { o.p.x += 1; o.n = o.n + 1; return 10; }
function setP(): int32 { o.p = { x: 9 }; return 10; }
function pairO(tag: string, a: int32, b: int32): int32 { seen.push(`${tag}: ${a} ${b}`); return 1; }
function wholeO(tag: string, a: Out, b: int32): int32 { seen.push(`${tag}: ${a.p.x} ${b}`); return 1; }

pairO("nested", o.p.x, bumpO());
pairO("again", o.p.x, bumpO());
wholeO("whole", o, bumpO());
setP();
o.n += 1;
seen.push(`end ${o.p.x} ${o.n} ${o.n}`);
console.log(seen.join("|"));
