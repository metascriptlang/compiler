
// Parked from valueStorage.ms for two open compiler defects. The first four
// tests hit the aggregate key-equality cold-path fallback: a synthesized `==`
// on a Set-typed map/set key emits raw C operands when the op registry is
// cold (card 2026-10-03-bitset-keyeq-cold-fallback). The last two hit the
// alias-analysis symbol-loss defect (card
// 2026-10-03-selfhost-noop-perturbation-flips-checker). Each group returns
// with its card's fix; the file stays unregistered in the lang tier index.
enum AggregateVectorFlagParked {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64,
}

function returnedAggregateSetVectorParked(): Vec<BitSet<AggregateVectorFlagParked>> {
	const value = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F0).incl(AggregateVectorFlagParked.F64);
	let values: Vec<BitSet<AggregateVectorFlagParked>> = [];
	values.push(value);
	return values;
}

test "valueStorage: returned aggregate-bitset vectors preserve independent value copies" {
	const original = returnedAggregateSetVectorParked();
	let copied = original;
	copied[0] = copied[0].excl(AggregateVectorFlagParked.F0);
	assert original[0].has(AggregateVectorFlagParked.F0);
	assert original[0].has(AggregateVectorFlagParked.F64);
	assert !copied[0].has(AggregateVectorFlagParked.F0);
	assert copied[0].has(AggregateVectorFlagParked.F64);
	copied = new Array(0);
	assert original[0].has(AggregateVectorFlagParked.F0);
}

test "valueStorage: nested aggregate-bitset vector copies retain independent inner buffers" {
	const inner = returnedAggregateSetVectorParked();
	const original: Vec<Vec<BitSet<AggregateVectorFlagParked>>> = [inner];
	let copied = original;
	copied[0][0] = copied[0][0].excl(AggregateVectorFlagParked.F64);
	assert original[0][0].has(AggregateVectorFlagParked.F64);
	assert !copied[0][0].has(AggregateVectorFlagParked.F64);
	assert copied[0][0].has(AggregateVectorFlagParked.F0);
	copied = new Array(0);
	assert original[0][0].has(AggregateVectorFlagParked.F64);
}

struct AggregateBitSetKeyParked { bits: BitSet<AggregateVectorFlagParked>; id: int32; }

test "valueStorage: equal aggregate-bitset map keys overwrite and delete one entry" {
	const first = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F0).incl(AggregateVectorFlagParked.F64);
	const equal = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F64).incl(AggregateVectorFlagParked.F0);
	const map: HashMap<BitSet<AggregateVectorFlagParked>, int32> = new HashMap();
	map.set(first, 17);
	map.set(equal, 23);
	assert map.size == 1;
	const found = map.get(first);
	assert found != null;
	if (found != null) { assert found == 23; }
	assert map.delete(equal);
	assert !map.has(first);
}

test "valueStorage: equal aggregate-bitset set members occupy one slot" {
	const first = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F0).incl(AggregateVectorFlagParked.F64);
	const equal = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F64).incl(AggregateVectorFlagParked.F0);
	const set: HashSet<BitSet<AggregateVectorFlagParked>> = new HashSet();
	set.add(first);
	set.add(equal);
	assert set.size == 1;
	assert set.delete(equal);
	assert !set.has(first);
}

test "valueStorage: struct keys compare aggregate-bitset fields by their values" {
	const first = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F0).incl(AggregateVectorFlagParked.F64);
	const equal = (0 as BitSet<AggregateVectorFlagParked>).incl(AggregateVectorFlagParked.F64).incl(AggregateVectorFlagParked.F0);
	const map: HashMap<AggregateBitSetKeyParked, int32> = new HashMap();
	map.set({ bits: first, id: 7 }, 17);
	const found = map.get({ bits: equal, id: 7 });
	assert found != null;
	if (found != null) { assert found == 17; }
	assert !map.has({ bits: equal, id: 8 });
}
