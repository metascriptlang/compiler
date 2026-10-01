// @xfail(raiser): raiser runtime error: attempt to access a nil address
// @stdout: 2,first,second,true,false|65 1 23 true true false 2 true true false|100 1 23 true true false 2 true true false|composite 1 23 1 23
// @exit: 0

enum E { A, B, C, D }
enum Flag65 {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64,
}
enum Flag100 {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64, F65, F66, F67, F68, F69, F70, F71, F72, F73, F74, F75, F76, F77, F78, F79,
	F80, F81, F82, F83, F84, F85, F86, F87, F88, F89, F90, F91, F92, F93, F94, F95,
	F96, F97, F98, F99,
}
struct AggregateKey { bits: BitSet<Flag65>; id: int32; }

function aggregate65(): string {
	const first = (0 as BitSet<Flag65>).incl(Flag65.F0).incl(Flag65.F64);
	const equal = (0 as BitSet<Flag65>).incl(Flag65.F64).incl(Flag65.F0);
	const other = (0 as BitSet<Flag65>).incl(Flag65.F1);
	const map: HashMap<BitSet<Flag65>, int32> = new HashMap();
	map.set(first, 17);
	map.set(equal, 23);
	map.set(other, 31);
	const found = map.get(equal);
	const hasFirst = map.has(first);
	const erased = map.delete(equal);
	const set: HashSet<BitSet<Flag65>> = new HashSet();
	set.add(first);
	set.add(equal);
	set.add(other);
	const before = set.size;
	const setFound = set.has(equal);
	const setErased = set.delete(equal);
	return `65 ${map.size} ${found != null ? found : -1} ${hasFirst} ${erased} ${map.has(first)} ${before} ${setFound} ${setErased} ${set.has(first)}`;
}

function aggregate100(): string {
	const first = (0 as BitSet<Flag100>).incl(Flag100.F0).incl(Flag100.F99);
	const equal = (0 as BitSet<Flag100>).incl(Flag100.F99).incl(Flag100.F0);
	const other = (0 as BitSet<Flag100>).incl(Flag100.F1);
	const map: HashMap<BitSet<Flag100>, int32> = new HashMap();
	map.set(first, 17);
	map.set(equal, 23);
	map.set(other, 31);
	const found = map.get(equal);
	const hasFirst = map.has(first);
	const erased = map.delete(equal);
	const set: HashSet<BitSet<Flag100>> = new HashSet();
	set.add(first);
	set.add(equal);
	set.add(other);
	const before = set.size;
	const setFound = set.has(equal);
	const setErased = set.delete(equal);
	return `100 ${map.size} ${found != null ? found : -1} ${hasFirst} ${erased} ${map.has(first)} ${before} ${setFound} ${setErased} ${set.has(first)}`;
}

function aggregateComposite(): string {
	const first = (0 as BitSet<Flag65>).incl(Flag65.F0).incl(Flag65.F64);
	const equal = (0 as BitSet<Flag65>).incl(Flag65.F64).incl(Flag65.F0);
	const structMap: HashMap<AggregateKey, int32> = new HashMap();
	structMap.set({ bits: first, id: 7 }, 17);
	structMap.set({ bits: equal, id: 7 }, 23);
	const structFound = structMap.get({ bits: equal, id: 7 });
	const tupleMap: HashMap<[BitSet<Flag65>, int32], int32> = new HashMap();
	tupleMap.set([first, 7], 17);
	tupleMap.set([equal, 7], 23);
	const tupleFound = tupleMap.get([equal, 7]);
	return `composite ${structMap.size} ${structFound != null ? structFound : -1} ${tupleMap.size} ${tupleFound != null ? tupleFound : -1}`;
}

function main(): void {
	const s: BitSet<E> = E.A | E.C;
	const t: BitSet<E> = E.B | E.D;
	const same: BitSet<E> = E.C | E.A;
	const m: HashMap<BitSet<E>, string> = new HashMap();
	m.set(s, "first");
	m.set(t, "second");
	const bySame = m.get(same);
	const byT = m.get(t);
	console.log(`${m.size},${bySame != null ? bySame : "none"},${byT != null ? byT : "none"},${m.has(same)},${m.has((0 as BitSet<E>).incl(E.B))}|${aggregate65()}|${aggregate100()}|${aggregateComposite()}`);
}
main();
