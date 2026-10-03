struct B614Big { a: int64; b: int64; c: int64; d: int64; e: int64; f: int64; g: int64; h: int64; }

function b614LoopBlock(s: int32, n: int32): int32 {
	let acc = 0;
	for (let i = 0; i < n; i += 1) {
		const s: int32 = 1000;
		acc = acc + s;
	}
	return acc + s;
}

function b614IfBlock(name: string): string {
	let out = "";
	if (name.length > 0) {
		const name: string = "inner";
		out = out + name;
	}
	return out + "/" + name;
}

function b614LargeStruct(big: B614Big, flag: boolean): int64 {
	let total = big.a;
	if (flag) {
		const big: int64 = 40;
		total = total + big;
	}
	return total + big.h;
}

function b614ArrowParam(): int32 {
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

test "parameterShadowing: a parameter read after a loop-block shadow keeps its value" {
	assert b614LoopBlock(7, 2) == 2007;
}
test "parameterShadowing: a parameter read after an if-block shadow keeps its value" {
	assert b614IfBlock("outer") == "inner/outer";
}
test "parameterShadowing: a struct parameter passed by pointer is not the shadow's storage" {
	const big: B614Big = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 };
	assert b614LargeStruct(big, true) == 49;
}
test "parameterShadowing: an arrow parameter read after a shadow keeps its value" {
	assert b614ArrowParam() == 35;
}
