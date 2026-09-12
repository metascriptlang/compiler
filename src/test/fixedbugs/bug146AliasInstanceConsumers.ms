// bug146 — a generic alias instance was still read raw by three consumers
// Symptom: `Setter<number>[]` calling `.slice(0, 1)` failed "in instantiation of 'slice<Setter>': Unresolved type
//          'Setter'" (the alias name never reached the generic body's scope); a field `Setter<number> | null` was
//          carried as a tagged union instead of a nullable function, so the js lane died with "cell.setter is not a
//          function"; and `typeRelation` compared a `Setter<number>` argument's TYPE-ARGUMENT list against a
//          `(v: number) => void` formal's parameters, accepting a closure whose parameter is an `msUnion*` for a
//          slot that passes a `double`.
// Root cause: injectConcreteTypeSyms had no GenericInstance arm; isMaybeWrappable and typeRelationInner did not
//             peel a transparent instance before switching on the kind.
// Fix: inject the alias symbol (and its arguments) for the body re-check; peel the instance in both predicates.

type Setter146<T> = (v: T | ((prev: T) => T)) => void;

interface Cell146 { setter: Setter146<number> | null; }

function mk146(): [() => number, Setter146<number>] {
	let cur = 0.5;
	return [() => cur, (v) => { if (typeof v === "function") { cur = v(cur); } else { cur = v; } }];
}

test "an alias instance array goes through a generic method" {
	const [get, set] = mk146();
	const xs: Setter146<number>[] = [set, set];
	const ys = xs.slice(0, 1);
	assert ys.length == 1;
	ys[0](2.5);
	assert get() == 2.5;
}

test "a nullable alias-over-function field is stored and called" {
	const [get, set] = mk146();
	const cell: Cell146 = { setter: null };
	cell.setter = set;
	if (cell.setter !== null) { cell.setter(4.5); }
	assert get() == 4.5;
	if (cell.setter !== null) { cell.setter(p => p * 2); }
	assert get() == 9;
}
