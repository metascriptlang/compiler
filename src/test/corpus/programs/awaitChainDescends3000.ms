// @stdout: 3001
// @stdout: 3001
// @xfail(raiser): the Raiser VM stops calls at depth 1024 with "call stack overflow", by design (src/raiser/vm.ms MAX_CALL_DEPTH)
// note: the descent of an await chain is ordinary recursion, as in Node, which itself fails at 10000 (card 2026-11-01-an-await-chain-10000-deep-overflows-the-stack-in-a-default-build); 3000 links of a function or a method fit a default build (a method chain overflows -O0 on macOS near 4000).

async function chain(depth: int32): Promise<int32> {
	if (depth == 0) return 1;
	return (await chain(depth - 1)) + 1;
}

class Walker {
	step: int32 = 1;
	async down(depth: int32): Promise<int32> {
		if (depth == 0) return this.step;
		return (await this.down(depth - 1)) + this.step;
	}
}

console.log(`${await chain(3000)}`);
console.log(`${await new Walker().down(3000)}`);
