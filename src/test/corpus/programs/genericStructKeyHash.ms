// Parity program — a generic struct instance keys a HashSet, Map or HashMap field by field like a
// plain struct, nested instances included; a class inside a struct key hashes by identity, so the
// key is found after the object it points at changes.
//
// @stdout: plain=2,true nested=1,1,true,1,1 wrapped=a,2 shared=1,1,1 apart=1,-1,2 mutated=2,true
// @exit: 0

struct Plain<T> { v: T; k: int32; }
struct Wrap<T> { v: T; }
class Todo { n: int32 = 0; }
class Pet { n: int32 = 0; }
struct Owned { pet: Pet; id: int32; }

const q = new HashSet<Plain<int32>>();
q.add({ v: 1, k: 2 });
q.add({ v: 1, k: 3 });
q.add({ v: 1, k: 2 });

const n1: Plain<Plain<int32>> = { v: { v: 1, k: 2 }, k: 3 };
const n2: Plain<Plain<int32>> = { v: { v: 1, k: 2 }, k: 3 };
const byNested = new Map<Plain<Plain<int32>>, int32>();
byNested.set(n1, 1);
const nestedSet = new HashSet<Plain<Plain<int32>>>();
nestedSet.add(n1);
nestedSet.add(n2);

const byName = new HashMap<Wrap<string>, string>();
byName.set({ v: "x" }, "a");
byName.set({ v: "y" }, "b");

const shared = new Todo();
const s1: Wrap<Todo> = { v: shared };
const s2: Wrap<Todo> = { v: shared };
const byShared = new Map<Wrap<Todo>, int32>();
byShared.set(s1, 1);
const sharedSet = new HashSet<Wrap<Todo>>();
sharedSet.add(s1);
sharedSet.add(s2);

const a1: Wrap<Todo> = { v: new Todo() };
const a2: Wrap<Todo> = { v: new Todo() };
const byApart = new Map<Wrap<Todo>, int32>();
byApart.set(a1, 1);
const apartSet = new HashSet<Wrap<Todo>>();
apartSet.add(a1);
apartSet.add(a2);

const pet = new Pet();
const owned = new HashSet<Owned>();
owned.add({ pet: pet, id: 1 });
pet.n = 7;
owned.add({ pet: pet, id: 1 });
owned.add({ pet: new Pet(), id: 1 });

console.log(`plain=${q.size},${q.has({ v: 1, k: 3 })} nested=${byNested.get(n1) ?? -1},${byNested.get(n2) ?? -1},${byNested.has(n2)},${byNested.size},${nestedSet.size} wrapped=${byName.get({ v: "x" }) ?? "-"},${byName.size} shared=${byShared.get(s2) ?? -1},${byShared.size},${sharedSet.size} apart=${byApart.get(a1) ?? -1},${byApart.get(a2) ?? -1},${apartSet.size} mutated=${owned.size},${owned.has({ pet: pet, id: 1 })}`);
