// An awaited string result is owned by the awaiting frame alone: a returning async function hands its string over, and a settle that takes a borrowed string leaves it with the caller.
// @stdout: v2
// @stdout: v2
// @stdout: kept w3
// @stdout: settled w3
// @exit: 0

async function str(): Promise<string> { return `v${1 + 1}`; }

async function main(): Promise<void> {
	const a = await str();
	console.log(a);
	console.log(await str());
	const p = new Promise<string>((resolve: (value: string) => void): void => {
		const s = `w${1 + 2}`;
		resolve(s);
		console.log(`kept ${s}`);
	});
	console.log(`settled ${await p}`);
}

main();
