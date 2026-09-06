// bug092 — loop + nested-closure: capture cell lost or read out of bounds
//
// Symptom:    A closure created inside a loop whose body contains ANOTHER
//             closure over the same outer var silently computed wrong values.
//             Module-level shape returned 0 forever (each call re-zeroed the
//             cell); in-function shape read/wrote `c` at offset 8 of an
//             8-byte env allocation (heap corruption that often read 0, or
//             NaN once the neighbouring slot got reused).
// Root cause: three stacked defects behind one late decision. `liftClosure`
//             chose shared-vs-per-closure env AFTER the body walk, so
//             `setupSharedEnv` wired the body's `$up` by casting `_envP` to
//             the enclosing fn's shared env — but at a loop site `_envP` is
//             the 8-byte per-closure pair env (out-of-bounds cast). And
//             `insideLoop` leaked into closure bodies, forcing inner closures
//             onto the snapshot path (writes went to a private copy). And the
//             captured cell lived in the closure's per-call env, so nothing
//             persisted across calls.
// Fix:        pre-walk `createSnapshotPairEnv` — at a loop site the pair env
//             is created BEFORE the body walk from the full capture set
//             (direct + nested refs) and becomes the persistent snapshot home;
//             the body's own shared env chains `$up` to it with a correctly
//             typed cast; `walkLiftBody` resets `insideLoop` per function
//             frame (every call site is a frame boundary).

type Bug092Fn = () => number;

const bug092Arr: Bug092Fn[] = [];
for (let bug092i = 0; bug092i < 2; bug092i++) {
	let c: number = 0;
	const step = () => {
		const inc = () => { c = c + 1; };
		inc();
		return c;
	};
	bug092Arr.push(step);
}

function bug092InFunction(): number[] {
	const out: number[] = [];
	for (let i = 0; i < 1; i++) {
		let c: number = 0;
		const step = () => {
			const inc = () => { c = c + 1; };
			inc();
			return c;
		};
		out.push(step());
		out.push(step());
	}
	return out;
}

function bug092ReadOnlyInner(): number[] {
	const arr: Bug092Fn[] = [];
	for (let i = 0; i < 2; i++) {
		let c: number = 0;
		const step = () => {
			const rd = () => { return c; };
			c = c + 1;
			return rd();
		};
		arr.push(step);
	}
	const out: number[] = [];
	out.push(arr[0]());
	out.push(arr[1]());
	out.push(arr[0]());
	return out;
}

test "bug092: module-level loop closure with nested writer keeps one persistent cell per iteration" {
	assert bug092Arr[0]() == 1;
	assert bug092Arr[0]() == 2;
	assert bug092Arr[1]() == 1;
}

test "bug092: in-function loop + nested closure increments its own cell across calls" {
	const r = bug092InFunction();
	assert r[0] == 1;
	assert r[1] == 2;
}

test "bug092: escaping loop closures see per-iteration cells through a read-only inner" {
	const a = bug092ReadOnlyInner();
	assert a[0] == 1;
	assert a[1] == 1;
	assert a[2] == 2;
}
