// An actor's onTerminate, onExit, onDown and onIdle may not spawn, await or call a function value
//
// INVARIANT (ULTRALOCK T7): the actor hooks LANG.md lists as lifecycle hooks obey the hook law the
//   memory hooks obey: no spawn, no await and no call through a function value, directly or through
//   a callee. Each shape below is one axis: a direct await, a spawn, a callee that awaits, a
//   function value, and an await inside the argument of a send to another actor, and a method of the
//   actor itself that awaits.
//
// RED MEANS: one of the hooks compiles again, or the refusal names another hook or actor.
//
// GUARD-JS
// GUARD-CHECK-FAIL lifecycle hook 'onTerminate' of 'Waits' must not spawn, await or call a function value, but it awaits
// GUARD-CHECK-FAIL lifecycle hook 'onExit' of 'Spawns' must not spawn, await or call a function value, but it calls 'kick'
// GUARD-CHECK-FAIL which spawns at 24:
// GUARD-CHECK-FAIL lifecycle hook 'onIdle' of 'Delegates' must not spawn, await or call a function value, but it calls 'pause'
// GUARD-CHECK-FAIL lifecycle hook 'onDown' of 'Calls' must not spawn, await or call a function value, but it calls a function value
// GUARD-CHECK-FAIL lifecycle hook 'onTerminate' of 'Feeds' must not spawn, await or call a function value, but it awaits
// GUARD-CHECK-FAIL lifecycle hook 'onTerminate' of 'Settles' must not spawn, await or call a function value, but it calls 'settle'

import { ExitReason } from "std/actor";

function pause(): void { await sleepAsync(1); }

async function kick(): Promise<int32> { return await spawn((): int32 => 42); }

let notify: () => void = (): void => {};

actor Waits {
	ping(): int32 { return 1; }
	onTerminate(reason: ExitReason): void { await sleepAsync(1); } // GUARD-REFUSED
}

actor Spawns {
	ping(): int32 { return 1; }
	onExit(childPid: int64, reason: ExitReason): void { kick(); } // GUARD-REFUSED
}

actor Delegates {
	ping(): int32 { return 1; }
	onIdle(): void { pause(); } // GUARD-REFUSED
}

actor Calls {
	ping(): int32 { return 1; }
	onDown(ref: number, pid: int64, reason: ExitReason): void { notify(); } // GUARD-REFUSED
}

actor Sink {
	ping(): int32 { return 1; }
	take(n: int32): void {}
}

actor Feeds {
	p: Sink = new Sink();
	ping(): int32 { return 1; }
	onTerminate(reason: ExitReason): void { this.p.take(await this.p.ping()); } // GUARD-REFUSED
}

actor Settles {
	settle(): void { await sleepAsync(1); }
	onTerminate(reason: ExitReason): void { this.settle(); } // GUARD-REFUSED
}

console.log("GUARD-OK");
