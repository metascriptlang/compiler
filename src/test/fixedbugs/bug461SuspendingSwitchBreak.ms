// bug461 — a break that leaves a switch early, inside a loop that suspends,
// broke the loop on C
//
// Symptom:    on C, `while (i < 4) { switch (i) { default: yield i * 10;
//             if (i == 1) break; yield i; } i++; }` did not compile, and the
//             same loop in an async function with an await in the case did
//             not compile either; with a string discriminant the generator
//             yielded nothing. JS was correct.
// Root cause: switchLower wraps such a switch in a labelled do-while(false)
//             and turns the break into `break <label>`; the generator
//             splitter in src/transform/lowering/generatorLower.ms did not
//             split a do-while or resolve a labelled break, and
//             src/transform/lowering/asyncBridge.ms did not look inside a
//             do-while for an await.
// Fix:        the splitter splits the wrapper and sends the labelled break to
//             the state after it (generatorLower, earlier commit); the async
//             bridge finds the await inside it.
//
// Guarded end-to-end by corpus/programs/925-suspendingSwitchBreak.ms.

function* b461Gen(): Iterator<int32> {
	let i: int32 = 0;
	while (i < 4) {
		switch (i) {
			default:
				yield i * 10;
				switch (i) {
					case 1:
						if (i > 0) break;
						yield 99;
						break;
					default:
						i += 0;
				}
				if (i == 1) break;
				yield i;
		}
		i++;
	}
}

function* b461GenString(): Iterator<string> {
	const names: string[] = ["a", "skip", "c"];
	let i: int32 = 0;
	while (i < 3) {
		const n = names[i];
		switch (n) {
			case "skip":
				yield "s";
				if (i > 0) break;
				yield "never";
				break;
			default:
				yield n;
		}
		i++;
	}
}

async function b461Tick(x: int32): Promise<int32> {
	return x;
}

async function b461Async(): Promise<string> {
	let out = "";
	let i: int32 = 0;
	while (i < 4) {
		switch (i) {
			default:
				const v = await b461Tick(i);
				if (v == 1) break;
				out = out + v.toString();
		}
		i++;
	}
	return out;
}

test "bug461: a generator loop whose switch is left early by a break" {
	let out = "";
	for (const v of b461Gen()) out = out + v.toString() + ",";
	assert out == "0,0,10,20,2,30,3,";
}

test "bug461: the same with a string discriminant" {
	let out = "";
	for (const v of b461GenString()) out = out + v + ",";
	assert out == "a,s,c,";
}

test "bug461: an async loop whose switch is left early by a break after an await" {
	assert await b461Async() == "023";
}
