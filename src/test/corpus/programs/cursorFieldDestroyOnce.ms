// @stdout: 2 3
// @stdout: 5
// note: A closure environment keeps its parent through a cursor field; destroying or copying the environment must not release or copy that borrowed parent, or the ledger sees a double release.

function counter(start: int32): () => int32 {
	let n = start;
	const bump = (): int32 => { n = n + 1; return n; };
	return bump;
}

function nested(): () => int32 {
	let base = 1;
	const inner = (): int32 => {
		const step = (): int32 => { base = base + 1; return base; };
		return step() + step();
	};
	return inner;
}

const c = counter(1);
console.log(`${c()} ${c()}`);
console.log(nested()());
