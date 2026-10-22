// A destroy hook that spawns a task borrowing `this` is refused at compile time
//
// INVARIANT (ULTRALOCK T7, 7b93f92bf): a lifecycle hook must not spawn, await or call a function
//   value, so no task can still borrow a cell its hook is destroying. This is the spawn-thunk
//   axis of collectedHookBorrowsThis, which the hook law moves from run time to the checker.
//
// WHAT IT CATCHES: the hook law no longer refusing a spawn inside onDestroy, or naming another
//   hook, type or site.
//
// RED MEANS: the build succeeds, or the refusal lost its text. Read the lifecycle-hook body check.
//
// GUARD-JS
// GUARD-CHECK-FAIL lifecycle hook 'onDestroy' of 'Lent' must not spawn, await or call a function value
// GUARD-CHECK-FAIL spawns at

class Lent { next: Lent | null = null; tag: int32 = 1; }

let hooks: int32 = 0;
let seen: int32 = 0;

function work(n: int32): int32 { return n + 1; }

function onDestroy(this x: Lent): void {
	const h = spawn(() => work(x.tag));
	seen += await h;
	hooks += 1;
}

const l = new Lent();
const m = new Lent();
l.next = m;
m.next = l;
console.log("GUARD-OK");
