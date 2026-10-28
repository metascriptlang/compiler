function firstValue(values: [string, int32][]): int32 {
	return values[0][1];
}

type TupleArrayCase<V> = V extends [string, int32][] ? int32 : string;
type ObjectArrayCase<V> = V extends { value: int32 }[] ? int32 : string;

test "tuple array parameter and variable annotations keep the element type" {
	const pair: [string, int32] = ["value", 7];
	const values: [string, int32][] = [pair];
	assert firstValue(values) == 7;
}

test "tuple atoms retain nested array suffixes" {
	const pair: [string, int32] = ["value", 7];
	const values: [string, int32][] = [pair];
	const nested: [string, int32][][] = [values];
	assert nested[0][0][1] == 7;
}

test "conditional extends sees tuple array operands" {
	const selected: TupleArrayCase<[string, int32][]> = 11;
	assert selected == 11;
}

test "conditional extends sees object array operands" {
	const selected: ObjectArrayCase<{ value: int32 }[]> = 13;
	assert selected == 13;
}
