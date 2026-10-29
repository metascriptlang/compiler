import { Box, data, plain, make, nodes } from "./fixtures/importedBindingShadow";

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

function constNodes(): int32 {
	const nodes: int32[] = [1, 2, 3];
	return nodes.length;
}

function letNodesInBlock(): int32 {
	let sum = 0;
	if (sum == 0) {
		let nodes: int32[] = [];
		nodes = [1, 2, 3, 4];
		sum = nodes.length;
	}
	return sum;
}

function nodesInArrow(): int32 {
	const count = (): int32 => {
		const nodes: int32[] = [1];
		return nodes.length;
	};
	return count();
}

function shadowedPlain(): int32 {
	const plain = (x: int32): int32 => x + 1;
	return plain(9);
}

test "a const local in another function leaves a test's read of an imported value bound to the import" {
	assert(constNodes() == 3);
	assert(nodes.length == 2);
}

test "a let local in a nested block of another function leaves a test's read of an imported value bound to the import" {
	assert(letNodesInBlock() == 4);
	assert(nodes.length == 2);
}

test "a local in a nested arrow of another function leaves a test's read of an imported value bound to the import" {
	assert(nodesInArrow() == 1);
	assert(nodes.length == 2);
}

test "a function-valued local in another function leaves a test's call bound to the imported function" {
	assert(shadowedPlain() == 10);
	assert(plain(3) == 6);
}
