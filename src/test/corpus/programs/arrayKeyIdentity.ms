// Parity program — an array, a Map or a Set keys a Map, HashMap, Set or HashSet by identity, as in
// TypeScript: the same array is found after it grows, an equal-content one is a different key.
//
// @stdout: todo=5,-1 hashset=1,-1,true,1,2 nested=1,-1,2 structs=1,-1 grow=a,-,a,false,true,false,true,false many=200,199,false holder=3,-1 mapkey=1,-1,1,2,true
// @exit: 0

interface Todo { id: number; }
struct P { a: int32; }

class Index<K> {
	m: Map<K, int32> = new Map<K, int32>();
	put(k: K, v: int32): void { this.m.set(k, v); }
	at(k: K): int32 { return this.m.get(k) ?? -1; }
}

const r1: Todo[] = [{ id: 1 }];
const r2: Todo[] = [{ id: 1 }];
const byTodos = new Map<Todo[], number>();
byTodos.set(r1, 5);

const n1: number[] = [1, 2];
const n2: number[] = [1, 2];
const n3 = n1;
const byNums = new Map<number[], int32>();
byNums.set(n1, 1);
const numSet = new HashSet<number[]>();
numSet.add(n1);
numSet.add(n2);

const g1: int32[][] = [[1]];
const g2: int32[][] = [[1]];
const byGrid = new Map<int32[][], int32>();
byGrid.set(g1, 1);
const gridSet = new Set<int32[][]>();
gridSet.add(g1);
gridSet.add(g2);

const p1: P[] = [{ a: 1 }];
const p2: P[] = [{ a: 1 }];
const byPs = new Map<P[], int32>();
byPs.set(p1, 1);

const k1: int32[] = [1];
const k2: int32[] = [1];
const m = new Map<int32[], string>();
const hm = new HashMap<int32[], string>();
const s = new Set<int32[]>();
const hs = new HashSet<int32[]>();
m.set(k1, "a"); hm.set(k1, "a"); s.add(k1); hs.add(k1);
for (let i = 0; i < 100; i++) { k1.push(i); }

const many = new Map<int32[], int32>();
const keys: int32[][] = [];
for (let i = 0; i < 200; i++) { const k: int32[] = [i]; keys.push(k); many.set(k, i); }
let found = 0;
for (let i = 0; i < 200; i++) { if ((many.get(keys[i]) ?? -1) == i) found++; }
many.delete(keys[5]);

const ix = new Index<string[]>();
const w1: string[] = ["a"];
const w2: string[] = ["a"];
ix.put(w1, 3);

const mk1 = new Map<string, int32>();
const mk2 = new Map<string, int32>();
const byMap = new Map<Map<string, int32>, int32>();
byMap.set(mk1, 1);
mk1.set("x", 1);
const e1 = new Set<int32>();
const bySet = new HashSet<Set<int32>>();
bySet.add(e1);
bySet.add(new Set<int32>());
bySet.add(e1);

console.log(`todo=${byTodos.get(r1) ?? -1},${byTodos.get(r2) ?? -1} hashset=${byNums.get(n1) ?? -1},${byNums.get(n2) ?? -1},${byNums.has(n3)},${byNums.size},${numSet.size} nested=${byGrid.get(g1) ?? -1},${byGrid.get(g2) ?? -1},${gridSet.size} structs=${byPs.get(p1) ?? -1},${byPs.get(p2) ?? -1} grow=${m.get(k1) ?? "-"},${m.get(k2) ?? "-"},${hm.get(k1) ?? "-"},${hm.has(k2)},${s.has(k1)},${s.has(k2)},${hs.has(k1)},${hs.has(k2)} many=${found},${many.size},${many.has(keys[5])} holder=${ix.at(w1)},${ix.at(w2)} mapkey=${byMap.get(mk1) ?? -1},${byMap.get(mk2) ?? -1},${byMap.size},${bySet.size},${bySet.has(e1)}`);
