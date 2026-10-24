// The same body written inline in the spawn and bound to a name first gets the same refusal: E24,
// "cannot write through Readonly<Holder>". The bound form also names the capture, the closure and where
// it is bound; a const alias of the closure is the closure.
//
// GUARD-CHECK-FAIL cannot write through Readonly<Holder> — a read-only view never converts back to the mutable type (PARALOCK E24)
// GUARD-CHECK-FAIL 'twinBound' is captured by 'cut', bound at
// GUARD-CHECK-FAIL 'twinAlias' is captured by 'cut', bound at
class Holder {
	n: int32;
	constructor() { this.n = 0; }
}

function inlineThunk(): int32 {
	const twinInline = new Holder();
	return await spawn((): int32 => { twinInline.n = 5; return 1; }); // GUARD-REFUSED
}

function boundThunk(): int32 {
	const twinBound = new Holder();
	const cut = (): int32 => { twinBound.n = 5; return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function aliasedThunk(): int32 {
	const twinAlias = new Holder();
	const cut = (): int32 => { twinAlias.n = 5; return 1; }; // GUARD-REFUSED
	const g = cut;
	return await spawn(g);
}

async function main(): Promise<void> {
	console.log(`r=${inlineThunk() + boundThunk() + aliasedThunk()}`);
}
main();
