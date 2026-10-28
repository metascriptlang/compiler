// @stdout: value position entries 2 sum 5
// @stdout: key position sum 1
// @stdout: number key sum 3
// note: iterating a Map whose key or value is a cyclic class lifts the entry tuple's destroy hook while the Map's own class hook is being lifted; the tuple hook releases the class through its own slot, never through the Map's drop owner
class Entry { next: Entry | null = null; key: string = ""; }

const a = new Entry();
a.key = "aa";
a.next = a;

const byName = new Map<string, Entry>();
byName.set("a", a);
byName.set("bb", new Entry());
let named: number = 0;
for (const [k, v] of byName) named += k.length + v.key.length;
console.log(`value position entries ${byName.size} sum ${named}`);

const byEntry = new Map<Entry, string>();
byEntry.set(new Entry(), "x");
let keyed: number = 0;
for (const [k, v] of byEntry) keyed += k.key.length + v.length;
console.log(`key position sum ${keyed}`);

const byNumber = new Map<number, Entry>();
byNumber.set(1, a);
let numbered: number = 0;
for (const [k, v] of byNumber) numbered += k + v.key.length;
console.log(`number key sum ${numbered}`);
