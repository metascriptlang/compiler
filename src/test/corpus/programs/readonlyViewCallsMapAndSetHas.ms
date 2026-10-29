// @stdout: map true false 2 set true false 2 hashmap true false hashset true false array 3 1 true 1 1 0
function mapView(v: Readonly<Map<string, number>>): string { return `map ${v.has("a")} ${v.has("z")} ${v.size}`; }
function setView(v: Readonly<Set<number>>): string { return `set ${v.has(3)} ${v.has(9)} ${v.size}`; }
function hashMapView(v: Readonly<HashMap<string, number>>): string { return `hashmap ${v.has("a")} ${v.has("z")}`; }
function gets(a: Readonly<Map<string, number>>, b: Readonly<HashMap<string, number>>): string { return `${a.readonlyGet("a")} ${b.readonlyGet("a")} ${b.readonlyGet("z") ?? 0}`; }
function hashSetView(v: Readonly<HashSet<number>>): string { return `hashset ${v.has(4)} ${v.has(9)}`; }
function arrayView(v: Readonly<number[]>): string { return `array ${v.length} ${v.indexOf(2)} ${v.includes(3)}`; }

const m = new Map<string, number>();
m.set("a", 1);
m.set("b", 2);
const s = new Set<number>();
s.add(3);
s.add(5);
const hm = new HashMap<string, number>();
hm.set("a", 1);
const hs = new HashSet<number>();
hs.add(4);
console.log(mapView(m), setView(s), hashMapView(hm), hashSetView(hs), arrayView([1, 2, 3]), gets(m, hm));
