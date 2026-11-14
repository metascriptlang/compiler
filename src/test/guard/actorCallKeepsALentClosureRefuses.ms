// nim-guard: an awaited actor call lends its closure argument, so the method must not keep it.
//
// INVARIANT (ULTRALOCK V6, V5): the closure passed to a method with a result is lent from the call
//   until the reply; the caller's frame keeps it and drops it afterwards. A method that stored it
//   in the actor's state would count the env on the actor's thread after the reply, beside the
//   caller's plain count, and would go on reading what the closure borrowed from the caller.
//   A method without a result is handed the closure and may keep it
//   (corpus `actorCallLendsAClosureUntilTheReply`).
//
// WHAT IT CATCHES: the state measured 2026-11-14 on main cf611b543e99, where both shapes passed
//   `msc check`; only a plain reference kept by the method was refused.
//
// RED MEANS: a method with a result keeps a closure it was only lent.
//
// GUARD-CHECK-FAIL keeps its parameter 'f'

class Box { v: int32 = 1; }

actor Keeper {
	cb: Sendable<() => int32> | null = null;
	keep(f: Sendable<() => int32>): int32 { this.cb = f; return 1; }
	later(): int32 { const g = this.cb; return g != null ? g() : 0; }
}

async function literalKept(k: Readonly<Keeper>): Promise<int32> {
	const box = new Box();
	return await k.keep(() => box.v); // GUARD-REFUSED
}

async function bindingKept(k: Readonly<Keeper>, n: int32): Promise<int32> {
	const f: Sendable<() => int32> = () => n;
	return await k.keep(f); // GUARD-REFUSED
}

const keeper = new Keeper();
console.log(await literalKept(keeper) + await bindingKept(keeper, 2) + await keeper.later());
