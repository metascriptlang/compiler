// @stdout: num=1.5,none int=7,9 bool=true,none chain=3,-1 moved=p!,null,x
class Box { f: int32 = 3; }
const boxes = new Map<string, Box>();
boxes.set("a", new Box());
function num(v: number, on: boolean): number | null { return on ? v : null; }
function int(v: int32): int32 | null { return v > 0 ? v : null; }
function flag(on: boolean): boolean | null { return on ? true : null; }
function moved(s: string, n: boolean): string | null { const t = s + "!"; return n ? null : t; }

const n1 = num(1.5, true) ?? -1;
const n2 = num(2, false);
const i1 = int(7) ?? 0;
const i2 = int(0) ?? 9;
const chain1 = boxes.get("a")?.f ?? -1;
const chain2 = boxes.get("b")?.f ?? -1;
console.log(`num=${n1},${n2 == null ? "none" : "some"} int=${i1},${i2} bool=${flag(true)},${flag(false) == null ? "none" : "some"} chain=${chain1},${chain2} moved=${moved("p", false)},${moved("p", true)},${moved("x", false)?.replace("!", "")}`);
