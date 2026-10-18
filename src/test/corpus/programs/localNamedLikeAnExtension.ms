// @stdout: one3 one7 one2 one9
// note: a local, a parameter or a loop binding spelled like an extension is its own symbol: the extension call beside it still reaches the extension, and the binding still reads its own value.

function show(this s: string): string { return "one"; }

function viaLocal(): string {
	const show = 3;
	return "a".show() + show.toString();
}

function viaParam(show: int32): string {
	return "a".show() + show.toString();
}

function viaLoop(): string {
	let out = "";
	for (const show of [2]) out = out + "a".show() + show.toString();
	return out;
}

function viaBlock(): string {
	let out = "";
	{
		const show = 9;
		out = "a".show() + show.toString();
	}
	return out;
}

console.log(`${viaLocal()} ${viaParam(7)} ${viaLoop()} ${viaBlock()}`);
