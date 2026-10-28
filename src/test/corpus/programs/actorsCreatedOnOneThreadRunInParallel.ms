// @stdout: two actors: stolen
// @stdout: two actors made inside a third: stolen
// @stdout: one actor twice: at most 1 at a time
// @exit: 0
// @serial
// @skip-js: the JS backend runs actors on one thread
// note: a queued actor wakes an idle worker that steals it (old: two actors created on the main thread ran one after the other and nothing was stolen). A spinner waits until a steal is counted, at most 5 s, so the output does not depend on how loaded the host is; one actor still runs one message at a time (A2)

@include("runtime/actor/actor.h");
extern function msActorStolenVisits(): int64;
import { lockedRead, lockedUpdate } from "std/core/promise";

struct Visits { inside: int32; most: int32; }

const visits: Locked<Visits> = new Locked({ inside: 0, most: 0 });

actor Spinner {
	spin(base: int64): int64 {
		const start = performance.now();
		while (msActorStolenVisits() == base && performance.now() - start < 5000) {}
		return msActorStolenVisits();
	}
}

actor Spawner {
	pair(): int64 {
		const a = new Spinner();
		const b = new Spinner();
		const before = msActorStolenVisits();
		await Promise.all([a.spin(before), b.spin(before)]);
		return msActorStolenVisits() - before;
	}
}

actor Once {
	hold(): int32 {
		lockedUpdate(visits, (v: Visits): Visits => { return { inside: v.inside + 1, most: v.inside + 1 > v.most ? v.inside + 1 : v.most }; });
		const start = performance.now();
		while (performance.now() - start < 100) {}
		lockedUpdate(visits, (v: Visits): Visits => { return { inside: v.inside - 1, most: v.most }; });
		return 0;
	}
}

const a = new Spinner();
const b = new Spinner();
await Promise.all([a.spin(0), b.spin(0)]);
console.log(`two actors: ${msActorStolenVisits() > 0 ? "stolen" : "not stolen"}`);

const outer = new Spawner();
console.log(`two actors made inside a third: ${(await outer.pair()) > 0 ? "stolen" : "not stolen"}`);

const once = new Once();
const idle = [new Spinner(), new Spinner()];
const base = msActorStolenVisits();
await Promise.all([once.hold(), once.hold(), idle[0].spin(base), idle[1].spin(base)]);
const most = lockedRead(visits, (v: Visits): int32 => { return v.most; });
console.log(`one actor twice: ${most == 1 ? "at most 1 at a time" : "overlapped " + most}`);
