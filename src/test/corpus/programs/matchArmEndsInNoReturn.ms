// @stdout: ret=20 init=10 arg=40 thrown=bad 7 init=bad 8 arg=bad 9 never=stop 7 init=stop 8 arg=stop 9 unreachableArms=20,10,40
// note: an arm of a match expression that ends in throw, unreachable or a call to a never function yields no value: it stops there, and the other arms give the match its value, whether the match is returned, initializes a variable or is passed as an argument.

function stop(message: string): never {
	throw new Error(message);
}

function twice(x: int32): int32 {
	return x * 2;
}

function throwRet(raw: int32): int32 {
	return match (raw) {
		0 => 10,
		1 => 20,
		_ => { throw new Error("bad " + raw.toString()); },
	};
}

function throwInit(raw: int32): int32 {
	const v: int32 = match (raw) {
		0 => 10,
		1 => 20,
		_ => { throw new Error("bad " + raw.toString()); },
	};
	return v;
}

function throwArg(raw: int32): int32 {
	return twice(match (raw) {
		0 => 10,
		1 => 20,
		_ => { throw new Error("bad " + raw.toString()); },
	});
}

function neverRet(raw: int32): int32 {
	return match (raw) {
		0 => 10,
		1 => 20,
		_ => { stop("stop " + raw.toString()); },
	};
}

function neverInit(raw: int32): int32 {
	const v: int32 = match (raw) {
		0 => 10,
		1 => 20,
		_ => { stop("stop " + raw.toString()); },
	};
	return v;
}

function neverArg(raw: int32): int32 {
	return twice(match (raw) {
		0 => 10,
		1 => 20,
		_ => { stop("stop " + raw.toString()); },
	});
}

function unreachableRet(raw: int32): int32 {
	return match (raw) {
		0 => 10,
		1 => 20,
		_ => {
			console.log("bad " + raw.toString());
			unreachable;
		},
	};
}

function unreachableInit(raw: int32): int32 {
	const v: int32 = match (raw) {
		0 => 10,
		1 => 20,
		_ => { unreachable; },
	};
	return v;
}

function unreachableArg(raw: int32): int32 {
	return twice(match (raw) {
		0 => 10,
		1 => 20,
		_ => { unreachable; },
	});
}

function caught(run: (raw: int32) => int32, raw: int32): string {
	try {
		return run(raw).toString();
	} catch (e) {
		return (e as Error).message;
	}
}

console.log(`ret=${throwRet(1)} init=${throwInit(0)} arg=${throwArg(1)} thrown=${caught(throwRet, 7)} init=${caught(throwInit, 8)} arg=${caught(throwArg, 9)} never=${caught(neverRet, 7)} init=${caught(neverInit, 8)} arg=${caught(neverArg, 9)} unreachableArms=${unreachableRet(1)},${unreachableInit(0)},${unreachableArg(1)}`);
