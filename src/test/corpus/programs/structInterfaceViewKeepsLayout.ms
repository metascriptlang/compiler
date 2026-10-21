// @stdout: 1 2 2 4 4|1 2 2 7 2 1 9|2 2|2 2
struct Pt { x: number; y: number; }
struct Box<T> { u: T; v: T; }
interface HasX { x: number; }
interface HasY { y: number; }
interface HasV { v: int32; }
interface HasUV { u: int32; v: int32; }
type Spot = distinct Pt;
type Spot2 = distinct Spot;
type Boxed<T> = distinct Box<T>;
type Boxed2<T> = distinct Boxed<T>;
class Pc { x: number = 1; y: number = 2; }
type Pet = distinct Pc;
type Pet2 = distinct Pet;

function mkPt(): Pt { return { x: 3, y: 4 }; }
function mkBox(): Box<int32> { return { u: 5, v: 1 }; }
function readV<T>(box: Box<T>): int32 { return (box as HasV).v; }
function readBoxedV<T>(box: Boxed<T>): int32 { return (box as HasV).v; }

const p: Pt = { x: 1, y: 2 };
const s = p as Spot;
const s2 = s as Spot2;
const mono = `${(s as HasX).x} ${(s as HasY).y} ${(s2 as HasY).y} ${(mkPt() as HasY).y} ${((mkPt() as Spot) as HasY).y}`;

const b: Box<int32> = { u: 7, v: 2 };
const g = b as Boxed<int32>;
const g2 = g as Boxed2<int32>;
const viewed = g2 as HasUV;
const generic = `${(mkBox() as HasV).v} ${(b as HasV).v} ${(g as HasV).v} ${(g2 as HasUV).u} ${((g as Box<int32>) as HasV).v} ${((mkBox() as Boxed<int32>) as HasUV).v} ${viewed.u + viewed.v}`;

const pet = new Pc() as Pet;
const cls = `${(pet as HasY).y} ${((pet as Pet2) as HasY).y}`;

const inTemplate = `${readV(b)} ${readBoxedV(g)}`;

console.log(`${mono}|${generic}|${cls}|${inTemplate}`);
