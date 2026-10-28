// A sink parameter, a constructor parameter and a reassigned parameter still move
//
// INVARIANT (LANG.md move semantics): the borrowed-parameter refusal (moveOfBorrowedParamRejects.ms)
//   applies only to a function or method parameter that is not `sink` and is never reassigned in the
//   body, because the others own their value.
//
// RED MEANS: the check refuses a move the analyzer proves owned.
//
// GUARD-JS

struct Hooks { run: (n: int32) => int32; }

actor Holder {
	hooks: Hooks;
	constructor(hooks: Hooks) { this.hooks = hooks; }
	apply(n: int32): int32 {
		const run = this.hooks.run;
		return run(n);
	}
}

class Box {
	h: Hooks;
	constructor(h: Hooks) { this.h = move h; }
}

class Node { v: int32 = 0; }
function consumeNode(sink n: Node): int32 { return n.v; }
function reassigned(n: Node): int32 {
	n = new Node();
	return consumeNode(move n);
}

function hold(sink hooks: Hooks): Holder {
	return new Holder(move hooks);
}

const holder = hold({ run: (n: int32): int32 => n * 2 });
const box = new Box({ run: (n: int32): int32 => n + 1 });
if (await holder.apply(21) != 42 || box.h.run(1) != 2 || reassigned(new Node()) != 0) throw new Error("move of an owned parameter");
console.log("GUARD-OK");
