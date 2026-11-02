// @stdout: n 2 | c 20 | n 4 | c 40 | k 7 8
interface Scene { n: int32; }
function bump(this s: Scene): void { s.n = s.n + 1; }
function count(this s: Scene): int32 { return s.n * 10; }
struct Ref { scene: Cursor<Scene>; id: int32; }
class Keeper { k: int32 = 7; }
function grow(this k: Keeper): int32 { k.k = k.k + 1; return k.k; }
const s: Scene = { n: 1 };
const r: Ref = { scene: s, id: 0 };
r.scene.bump();
const out: string[] = [`n ${s.n}`, `c ${r.scene.count()}`];
const local: Cursor<Scene> = s;
local.bump();
local.bump();
out.push(`n ${s.n}`);
out.push(`c ${local.count()}`);
const keeper = new Keeper();
const held: Cursor<Keeper> = keeper;
const before = keeper.k;
out.push(`k ${before} ${held.grow()}`);
console.log(out.join(" | "));
