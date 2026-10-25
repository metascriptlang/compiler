struct FlagWordBox { v: int32; }

function bumpExtern(this externBox: FlagWordBox): int32 { return externBox.v + 1; }

function bumpAsync(this asyncBox: FlagWordBox): int32 { return asyncBox.v + 2; }

function bumpGenerator(this generatorBox: FlagWordBox): int32 { return generatorBox.v + 3; }

function bumpOverload(this overloadBox: FlagWordBox): int32 { return overloadBox.v + 4; }

function addThrough(this gen: FlagWordBox, k: int32): int32 {
	const add = (x: int32): int32 => x + gen.v;
	return add(k);
}

test "a receiver named externBox keeps its body" {
	const box: FlagWordBox = { v: 10 };
	assert box.bumpExtern() == 11;
}

test "a receiver named asyncBox keeps a plain return" {
	const box: FlagWordBox = { v: 10 };
	const n: int32 = box.bumpAsync();
	assert n == 12;
}

test "a receiver named generatorBox keeps a plain routine" {
	const box: FlagWordBox = { v: 10 };
	assert box.bumpGenerator() == 13;
}

test "a receiver named overloadBox keeps its implementation" {
	const box: FlagWordBox = { v: 10 };
	assert box.bumpOverload() == 14;
}

test "a receiver named gen keeps its closure lifted" {
	const box: FlagWordBox = { v: 10 };
	assert box.addThrough(5) == 15;
}
