// @stdout: before
// @stdout: The value of "size" is out of range. It must be >= 0 && <= 2147483647. Received -1
function size(n: int32): number {
	return n;
}

console.log("before");
try {
	const bad = Buffer.allocUnsafe(size(-1));
	console.log(`unreachable ${bad.length}`);
} catch (e) {
	console.log((e as Error).message);
}
