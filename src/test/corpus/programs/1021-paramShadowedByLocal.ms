// Parity program — a parameter read after a block local of the same spelling
// reads the parameter, in a plain function, a loop body and a lifted arrow.
//
// @stdout: 2007|inner/outer|35
// @exit: 0

function loopBlock(s: int32, n: int32): int32 {
	let acc = 0;
	for (let i = 0; i < n; i += 1) {
		const s: int32 = 1000;
		acc = acc + s;
	}
	return acc + s;
}

function ifBlock(name: string): string {
	let out = "";
	if (name.length > 0) {
		const name: string = "inner";
		out = out + name;
	}
	return out + "/" + name;
}

function arrowParam(): int32 {
	const f = (s: int32): int32 => {
		let got = 0;
		{
			const s: int32 = 5;
			got = s;
		}
		return got + s;
	};
	return f(30);
}

console.log(`${loopBlock(7, 2)}|${ifBlock("outer")}|${arrowParam()}`);
