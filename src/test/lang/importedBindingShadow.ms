import { Box, data, plain, make } from "./fixtures/importedBindingShadow";

function constLocal(): int32 {
	const box = make();
	const data = box.data();
	return data + 1;
}

function letLocal(): int32 {
	const box = make();
	let data = 0;
	data = box.data();
	return data + 1;
}

function paramLocal(box: Box, data: int32): int32 {
	return box.data() + data;
}

function nestedBlock(): int32 {
	const box = make();
	let sum = 0;
	if (sum == 0) {
		const data = box.data();
		sum = data;
	}
	return sum + 1;
}

function plainParamLocal(plain: int32): int32 {
	return plain + 1;
}

test "a const local named like an imported this-function leaves the call bound to the import" {
	assert(constLocal() == 8);
}

test "a let local named like an imported this-function leaves the call bound to the import" {
	assert(letLocal() == 8);
}

test "a parameter named like an imported this-function leaves the call bound to the import" {
	assert(paramLocal(make(), 1) == 8);
}

test "a block local named like an imported this-function leaves the call bound to the import" {
	assert(nestedBlock() == 8);
}

test "a parameter named like an imported function leaves a call elsewhere bound to the import" {
	assert(plainParamLocal(1) == 2);
	assert(plain(3) == 6);
}
