// @stdout: gs=0,2,3, gn=0,3, ga=a0f0a1f1a2f2 as=0,2,3, an=0,3, af=b0f0f1b2f2 aw=0,2,
function* genSwitch(): Iterator<int32> {
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return;
		switch (i) {
			case 1:
				continue;
			default:
				break;
		}
		yield i;
	}
}

function* genNested(): Iterator<int32> {
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return;
		switch (i) {
			case 1:
			case 2:
				switch (i) {
					case 2:
						continue;
					default:
						break;
				}
				continue;
			default:
				break;
		}
		yield i;
	}
}

function* genFinally(): Iterator<string> {
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		guard += 1;
		if (guard > 20) return;
		try {
			yield "a" + i.toString();
			if (i == 1) continue;
		} finally {
			yield "f" + i.toString();
		}
	}
}

async function tick(x: int32): Promise<int32> { return x; }

async function asyncSwitch(): Promise<string> {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		switch (i) {
			case 1:
				continue;
			default:
				break;
		}
		out += (await tick(i)).toString() + ",";
	}
	return out;
}

async function asyncNested(): Promise<string> {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		switch (i) {
			case 1:
			case 2:
				switch (i) {
					case 2:
						continue;
					default:
						break;
				}
				continue;
			default:
				break;
		}
		out += (await tick(i)).toString() + ",";
	}
	return out;
}

async function asyncFinally(): Promise<string> {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		try {
			await tick(i);
			if (i == 1) continue;
			out += "b" + i.toString();
		} finally {
			out += "f" + i.toString();
		}
	}
	return out;
}

async function whileSwitch(): Promise<string> {
	let out = "";
	let i: int32 = 0;
	let guard: int32 = 0;
	while (i < 4) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		const k = i;
		i += 1;
		switch (k) {
			case 1:
				continue;
			case 3:
				continue;
			default:
				break;
		}
		out += (await tick(k)).toString() + ",";
	}
	return out;
}

function drain(g: Iterator<int32>): string {
	let out = "";
	for (const v of g) out += v.toString() + ",";
	return out;
}

function drainStr(g: Iterator<string>): string {
	let out = "";
	for (const v of g) out += v;
	return out;
}

console.log(`gs=${drain(genSwitch())} gn=${drain(genNested())} ga=${drainStr(genFinally())} as=${await asyncSwitch()} an=${await asyncNested()} af=${await asyncFinally()} aw=${await whileSwitch()}`);
