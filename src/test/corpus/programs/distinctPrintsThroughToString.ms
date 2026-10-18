// @stdout: S5 S5 S5 S5 a=S5 | S5 S5 | <1,2> <1,2> <1,2> <1,2> | S3 S4 calls=2
type Small = distinct int8;
function toString(this x: Small): string { return "S" + (x as int8).toString(); }
type Tiny = distinct Small;
@delegate function toString(this t: Tiny): string;

struct Vec2 { x: int32; y: int32; }
function toString(this v: Vec2): string { return `<${v.x},${v.y}>`; }
type Pos = distinct Vec2;
@delegate function toString(this p: Pos): string;

let calls = 0;
function mk(v: int32): Small { calls++; return v as Small; }

const s = 5 as Small;
let acc = "a=";
acc += s;
const t = (5 as Small) as Tiny;
const p = ({ x: 1, y: 2 } as Vec2) as Pos;
console.log(s);
console.log(t);
console.log(p);
console.log(`${s} ${String(s)} ${"" + s} ${s.toString()} ${acc} | ${t} ${String(t)} | ${p} ${String(p)} ${"" + p} ${p.toString()} | ${mk(3)} ${mk(4)} calls=${calls}`);
