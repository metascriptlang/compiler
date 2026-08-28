// @stdout: array-mutator-legal 2 2 2 2

function addAll(dst: int32[], n: int32): int32 {
	dst.push(n);
	return dst.length;
}

let own: Vec<int32> = [];
own.push(1);
own.push(2);
const refs: int32[][] = [[1], [2]];
for (const q of refs) {
	q.push(9);
}
console.log("array-mutator-legal", addAll([5], 6), own.length, refs[0].length, refs[1].length);
