// guard: a class holding an owned-element container beside a plain one stays cyclic, so its cycles are collected
//
// INVARIANT (reference types.nim canFormAcycleAux, the marker keyed by type id, so seq[owned N] and seq[N] are
//   distinct visits): cycle analysis marks a container instance as visited per element edge kind, so meeting
//   `Vec<Owned<N>>` first never hides a later `Vec<N>` field that leads back to N through a plain edge.
//
// WHAT IT CATCHES: the visited key taken from the instance's output spelling, which is the same for
//   `Vec<Owned<N>>` and `Vec<N>`; the class then classifies acyclic only when the owned field comes first,
//   and every cycle through the plain field leaks (alloc=N destroy=0).
//
// AXES: owned container first vs plain first; `Vec` vs `T[]` for the plain field; an `Unowned` container first.
//
// RED MEANS: the field order changed a type's cycle classification. Run /trace-ref on cycles.ms identityOf.
// GUARD-BALANCE OwnedFirst
// GUARD-BALANCE PlainFirst
// GUARD-BALANCE OwnedThenArray
// GUARD-BALANCE UnownedFirst

class OwnedFirst { kids: Vec<Owned<OwnedFirst>> = []; refs: Vec<OwnedFirst> = []; }
class PlainFirst { refs: Vec<PlainFirst> = []; kids: Vec<Owned<PlainFirst>> = []; }
class OwnedThenArray { kids: Vec<Owned<OwnedThenArray>> = []; refs: OwnedThenArray[] = []; }
class UnownedFirst { back: Vec<Unowned<UnownedFirst>> = []; refs: Vec<UnownedFirst> = []; }

function churn(): int32 {
	let made: int32 = 0;
	for (let i: int32 = 0; i < 200; i++) {
		const a = new OwnedFirst();
		const b = new OwnedFirst();
		a.refs.push(b);
		b.refs.push(a);
		const c = new PlainFirst();
		const d = new PlainFirst();
		c.refs.push(d);
		d.refs.push(c);
		const e = new OwnedThenArray();
		const e2 = new OwnedThenArray();
		e.refs.push(e2);
		e2.refs.push(e);
		const f = new UnownedFirst();
		const g = new UnownedFirst();
		f.refs.push(g);
		g.refs.push(f);
		made += 8;
	}
	return made;
}

console.log("made", churn());
