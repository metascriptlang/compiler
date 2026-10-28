// An object spread of a borrowed struct whose fields are all Sendable closures is an owned copy
//
// INVARIANT (ULTRALOCK views): `{ ...view }` over fields that are plain data or Sendable closures
//   copies values nothing else owns: a Sendable closure was checked where it was built and its
//   environment is shared immutable state, so the copy takes no count on the view. A struct
//   holding a plain closure or a class stays refused (spreadOfNonSendableViewRejects.ms).
//
// RED MEANS: the spread exemption (spreadCopiesRefFree) stopped admitting Sendable leaves.
//
// GUARD-JS

struct Services {
	a: Sendable<(n: int32) => Promise<int32>>;
	b: Sendable<(n: int32) => Promise<int32>>;
}

class Session {
	services: Services;
	constructor(services: Services) { this.services = services; }
}

async function accept(services: Readonly<Services>): Promise<int32> {
	const session = new Session({ ...services });
	return await session.services.a(1) + await session.services.b(10);
}

function build(): Sendable<() => Promise<int32>> {
	const services: Services = {
		a: async (n: int32): Promise<int32> => n + 1,
		b: async (n: int32): Promise<int32> => n + 2,
	};
	return async (): Promise<int32> => await accept(services);
}

const run = build();
const n = await run();
if (n != 14) throw new Error(`n=${n}`);
console.log("GUARD-OK");
