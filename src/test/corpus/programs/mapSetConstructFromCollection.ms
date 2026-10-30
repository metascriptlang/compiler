// @stdout: 2 a b 2 a1
// @stdout: 2 1 2 | 3
// @stdout: 2 2 true
// @stdout: 3 4
// @stdout: 1 2 | 2 3
const src = new Map<int32, string>([[1, "a"], [2, "b"]]);
const copy = new Map(src);
copy.set(1, "a1");
copy.delete(2);
copy.set(3, "c");
console.log(`${src.size} ${src.get(1)} ${src.get(2)} ${copy.size} ${copy.get(1)}`);

const pairs: Array<[string, int32]> = [["x", 1], ["y", 2]];
const fromPairs = new Map(pairs);
const again = new Map(fromPairs);
again.set("z", 3);
console.log(`${fromPairs.size} ${again.get("x")} ${again.get("y")} | ${again.size}`);

const base = new Set<string>(["p", "q"]);
const dup = new Set(base);
dup.add("r");
dup.delete("p");
console.log(`${base.size} ${dup.size} ${base.has("p")}`);

const fromArr = new Set([1, 2, 2, 3]);
const fromSet = new Set(fromArr);
fromSet.add(9);
console.log(`${fromArr.size} ${fromSet.size}`);

const hm = new HashMap<string, string>([["k", "v"]]);
const hmCopy = new HashMap(hm);
hmCopy.set("k2", "v2");
const hs = new HashSet<int32>([1, 2]);
const hsCopy = new HashSet(hs);
hsCopy.add(3);
console.log(`${hm.size} ${hmCopy.size} | ${hs.size} ${hsCopy.size}`);
