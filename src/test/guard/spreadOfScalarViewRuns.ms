// A spread of a borrowed Vec of scalars owns its storage, so a Sendable function may pass the view on
//
// INVARIANT (ULTRALOCK views): `[...view]` over scalar elements copies the elements into fresh storage,
//   so storing it takes no count on the view and the callee's copy stays its own when the caller
//   mutates the original afterwards. A spread of refs stays refused (spreadOfRefViewRejects.ms).
//
// RED MEANS: E-view treats a spread of scalars as storing the view, or the spread aliases its source.
//
// GUARD-JS

struct Row { key: Vec<uint8>; }
struct Services { lifecycle: Sendable<(sender: Vec<uint8>) => Promise<int32>>; }

async function outcome(services: Readonly<Services>, sender: Readonly<Vec<uint8>>): Promise<int32> {
	return await services.lifecycle([...sender]);
}

async function accept(sender: Readonly<Vec<uint8>>, services: Readonly<Services>): Promise<int32> {
	return await outcome(services, sender);
}

function copyKey(rows: Readonly<Vec<Row>>): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (const row of rows) {
		const key: Vec<uint8> = [...row.key];
		out = move key;
	}
	return out;
}

function build(sender: Vec<uint8>, rows: Vec<Row>): Sendable<() => Promise<int32>> {
	const services: Services = { lifecycle: async (s: Vec<uint8>): Promise<int32> => s.length as int32 };
	return async (): Promise<int32> => await accept(sender, services) + copyKey(rows).length as int32;
}

async function main(): Promise<void> {
	let sender: Vec<uint8> = [1, 2, 3];
	const rows: Vec<Row> = [{ key: [7, 8] }];
	const run = build(sender, rows);
	const n = await run();
	const copy: Vec<uint8> = [...sender];
	sender[0] = 9;
	if (n != 5 || copy[0] != 1) throw new Error(`n=${n} copy0=${copy[0]}`);
	console.log("GUARD-OK");
}

await main();
