// A closure bound to a name and spawned reads its captures as Readonly, as an inline thunk does, so a
// write the closure makes into a captured graph is refused even when the parent only reads it. The write
// is found through the partition of its root: an alias of the capture, a nested arrow, a loop binding over
// a captured array, a callee that writes its argument and a call through a function value all reach it.
// The legal neighbour (read-only captures) is pinned by spawnNamedClosureAccepts.ms.
//
// GUARD-CHECK-FAIL 'directRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'aliasRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'nestRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'loopItems' is captured by 'cut'
// GUARD-CHECK-FAIL 'methodRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'calleeRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'valueRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'thunkRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'declRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'viaRing' is captured by 'bump'
// GUARD-CHECK-FAIL 'constAliasRing' is captured by 'cut'
// GUARD-CHECK-FAIL 'hopAliasRing' is captured by 'cut'
class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder {
	child: Child;
	n: int32;
	constructor(c: Child) { this.child = c; this.n = 0; }
	bump(): void { this.n += 1; }
}

function touch(h: Holder): void { h.n = 9; }

function direct(): int32 {
	const directRing = new Holder(new Child(1));
	const cut = (): int32 => { directRing.n = 5; return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function aliased(): int32 {
	const aliasRing = new Holder(new Child(1));
	const cut = (): int32 => { const r = aliasRing; r.n = 5; return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function nestedArrow(): int32 {
	const nestRing = new Holder(new Child(1));
	const cut = (): int32 => {
		const write = (): void => { nestRing.n = 5; }; // GUARD-REFUSED
		write();
		return 1;
	};
	return await spawn(cut);
}

function overCapturedArray(): int32 {
	const loopItems: Holder[] = [new Holder(new Child(1)), new Holder(new Child(2))];
	const cut = (): int32 => {
		for (const item of loopItems) { item.n = 5; } // GUARD-REFUSED
		return 1;
	};
	return await spawn(cut);
}

function writingMethod(): int32 {
	const methodRing = new Holder(new Child(1));
	const cut = (): int32 => { methodRing.bump(); return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function writingCallee(): int32 {
	const calleeRing = new Holder(new Child(1));
	const cut = (): int32 => { touch(calleeRing); return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function throughFunctionValue(apply: Sendable<(h: Holder) => void>): int32 {
	const valueRing = new Holder(new Child(1));
	const cut = (): int32 => { apply(valueRing); return 1; }; // GUARD-REFUSED
	return await spawn(cut);
}

function calledFromThunk(): int32 {
	const thunkRing = new Holder(new Child(1));
	const cut = (): int32 => { thunkRing.n = 5; return 1; }; // GUARD-REFUSED
	return await spawn((): int32 => cut());
}

async function nestedDeclCaller(): Promise<int32> {
	const declRing = new Holder(new Child(1));
	const cut = (): int32 => { declRing.n = 5; return 1; }; // GUARD-REFUSED
	async function run(): Promise<int32> { return await spawn(cut); }
	return await run();
}

function throughCalledClosure(): int32 {
	const viaRing = new Holder(new Child(1));
	const bump = (): void => { viaRing.n += 1; }; // GUARD-REFUSED
	const cut = (): int32 => { bump(); return 1; };
	return await spawn(cut);
}

function throughConstAlias(): int32 {
	const constAliasRing = new Holder(new Child(1));
	const cut = (): int32 => { constAliasRing.n = 5; return 1; }; // GUARD-REFUSED
	const g = cut;
	return await spawn(g);
}

function throughTwoHopAlias(): int32 {
	const hopAliasRing = new Holder(new Child(1));
	const cut = (): int32 => { hopAliasRing.n = 5; return 1; }; // GUARD-REFUSED
	const g = cut;
	const h = g;
	return await spawn(h);
}

async function main(): Promise<void> {
	console.log(`r=${direct() + aliased() + nestedArrow() + overCapturedArray() + writingMethod() + writingCallee()
		+ throughFunctionValue(touch) + calledFromThunk() + await nestedDeclCaller() + throughCalledClosure() + throughConstAlias() + throughTwoHopAlias()}`);
}
main();
