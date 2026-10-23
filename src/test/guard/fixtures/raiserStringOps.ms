class O { n: int64 = 7; }

function both(a: string, b: string): string { return a + b; }
function mixed(a: string, n: int64): string { return a + n; }
function at(s: string, i: int32): int32 { return s.byteAt(i); }

const o = new O();
let s = "ab";
for (let i = 0; i < 5; i++) s = s + s;
console.log(`${both("x", "y")} ${mixed("a", 1)} ${"a" + 1} ${s.length} ${s.slice(0, 4)} t${o.n}u`);

const k = "h" + "é";
console.log(`${at(k, 0)} ${at(k, 1)} ${at(k, 2)} ${at(k, 3)} ${at(k, -1)} ${at("", 0)}`);

const m = new Map<string, int64>();
const parts = ["k", "k"];
m.set("k1", 1);
m.set(parts[0] + 1, 2);
const built = "k" + (0 + 1);
m.set(built, (m.get("k1") ?? 0) + 10);
console.log(`${m.size} ${m.get("k1")} ${m.has(parts[1] + 1)} ${m.delete(built)} ${m.has("k1")}`);
