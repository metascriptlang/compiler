// @stdout: ok 1 0 2
// @exit: 0
// @xfail(raiser): raiser pop sets the length from a Float and stops with "ArraySetLen expected an integer length, got kind Float" (inbox 2026-09-25-raiser-array-pop-fails)
// note: a generic class's method and a generic function call std's generic `pop` on an array whose element type still names their own `T` (`Q<T>[]`, one level deeper `Q<Q<T>>[]`). Checking the generic body before its instantiation must not instantiate `pop` over the unbound `T`: such an instance is never defined, and the JS bundle exported its name from std's array module ("Export … is not defined in module").

interface Q<T> {
	ops: T[];
}

class Hub<T> {
	private queues: Q<T>[] = [];
	attach(): Q<T> {
		const q: Q<T> = { ops: [] };
		this.queues.push(q);
		return q;
	}
	drop(): int32 {
		this.queues.pop();
		return this.queues.length as int32;
	}
}

class Nest<T> {
	levels: Q<Q<T>>[] = [];
	add(): void { this.levels.push({ ops: [] }); }
	drop(): int32 {
		this.levels.pop();
		return this.levels.length as int32;
	}
}

function drain<T>(qs: Q<T>[]): int32 {
	qs.pop();
	return qs.length as int32;
}

function main(): void {
	const h = new Hub<int32>();
	h.attach();
	h.attach();
	const n = new Nest<string>();
	n.add();
	const qs: Q<boolean>[] = [{ ops: [] }, { ops: [] }, { ops: [] }];
	console.log(`ok ${h.drop()} ${n.drop()} ${drain<boolean>(qs)}`);
}

main();
