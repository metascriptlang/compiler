// MetaScript JSON — Type Tests
// JsonKind and JsonValue are defined in index.cms (prelude — auto-loaded).

test "JsonKind values" {
	assert JsonKind.Null === 0;
	assert JsonKind.Bool === 1;
	assert JsonKind.Number === 2;
	assert JsonKind.String === 3;
	assert JsonKind.Array === 4;
	assert JsonKind.Object === 5;
}

test "JsonValue construct null" {
	const v = new JsonValue(JsonKind.Null, false, 0, "", [], [], []);
	assert v.kind === JsonKind.Null;
	assert v.boolVal === false;
	assert v.numVal === 0;
	assert v.strVal === "";
	assert v.arrVal.length === 0;
	assert v.objKeys.length === 0;
	assert v.objVals.length === 0;
}

test "JsonValue construct bool" {
	const v = new JsonValue(JsonKind.Bool, true, 0, "", [], [], []);
	assert v.kind === JsonKind.Bool;
	assert v.boolVal === true;
}

test "JsonValue construct number" {
	const v = new JsonValue(JsonKind.Number, false, 42, "", [], [], []);
	assert v.kind === JsonKind.Number;
	assert v.numVal === 42;
}

test "JsonValue construct string" {
	const v = new JsonValue(JsonKind.String, false, 0, "hello", [], [], []);
	assert v.kind === JsonKind.String;
	assert v.strVal === "hello";
}

test "JsonValue construct array with children" {
	const child1 = new JsonValue(JsonKind.Number, false, 1, "", [], [], []);
	const child2 = new JsonValue(JsonKind.Number, false, 2, "", [], [], []);
	const arr: JsonValue[] = [child1, child2];
	const v = new JsonValue(JsonKind.Array, false, 0, "", arr, [], []);
	assert v.kind === JsonKind.Array;
	assert v.arrVal.length === 2;
	assert v.arrVal[0].numVal === 1;
	assert v.arrVal[1].numVal === 2;
}

test "JsonValue construct object with entries" {
	const val1 = new JsonValue(JsonKind.String, false, 0, "world", [], [], []);
	const keys: string[] = ["hello"];
	const vals: JsonValue[] = [val1];
	const v = new JsonValue(JsonKind.Object, false, 0, "", [], keys, vals);
	assert v.kind === JsonKind.Object;
	assert v.objKeys.length === 1;
	assert v.objKeys[0] === "hello";
	assert v.objVals[0].strVal === "world";
}
