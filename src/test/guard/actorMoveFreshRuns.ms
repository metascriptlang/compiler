// nim-guard: an isolated field, a destructured fresh value and a spread copy cross into an actor.
//
// INVARIANT (ULTRALOCK V2, N5): a field moved out of a local bound from a fresh value and never
//   aliased crosses to the actor; so does a binding destructured from a fresh value, and a spread
//   of a T[] or a Buffer of value-only elements, which builds a fresh array.
//
// WHAT IT CATCHES: the path check refusing a sole owner's field, a destructured binding reported
//   as declared outside its function, and `[...b] as Buffer` or `[...a]` refused as "not a fresh
//   value" (no spelling of a fresh copy compiled on msc ad50eb00424); and a Result's value
//   narrowed by `if (!r.ok)` refused as "not a fresh value" when its struct holds an array, because
//   the narrowed read arrives wrapped in a conversion the path check did not peel (8e5d42d129b).
//
// RED MEANS: the build fails on one of the moves below, or the actor saw the wrong lengths.

struct Read {
	step: int32;
	data: Buffer;
	reply: Buffer;
}

function next(i: int32): Read {
	return { step: i, data: Buffer.alloc(1 + i), reply: Buffer.alloc(3) };
}

struct State {
	name: string;
	items: int32[];
}

function made(name: string): Result<State, string> {
	return Result.ok({ name: name, items: [1, 2, 3] });
}

actor Sink {
	total: int32 = 0;
	frame(data: Buffer): int32 { this.total += data.length; return this.total; }
	raw(data: uint8[]): int32 { this.total += data.length; return this.total; }
	state(s: State): int32 { this.total += s.items.length; return this.total; }
}

async function main(): Promise<int32> {
	const sink = new Sink();
	for (let i: int32 = 0; i < 2; i++) {
		let got = next(i);
		if (got.step == 1) await sink.frame(move got.reply);
		if (got.step == 0) await sink.frame(move got.data);
	}
	const { data } = next(4);
	await sink.frame(move data);
	const shared: Buffer = Buffer.alloc(7);
	const copy = [...shared] as Buffer;
	await sink.frame(move copy);
	const src: uint8[] = [1, 2];
	let plain: uint8[] = [...src];
	await sink.raw(move plain);
	const r = made("a");
	if (!r.ok) return 1;
	await sink.state(move r.value);
	let total: int32 = 0;
	{
		const inner = made("b");
		if (!inner.ok) return 1;
		total = await sink.state(move inner.value);
	}
	if (total != 1 + 3 + 5 + 7 + 2 + 3 + 3 || shared.length != 7 || src.length != 2) { throw "GUARD RED: total " + total; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(await main());
