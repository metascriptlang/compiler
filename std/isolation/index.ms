/**
 * A value whose reference graph is reachable only through this wrapper, so it can
 * cross to an actor or a thread by `move` through any number of layers. The wrapper
 * has no copy: pass it on with `move`, and take the value out with `extract`.
 */
@builtin("Isolated")
export struct Isolated<T> {
	value: T;
}

/** A destroy hook with no `onCopy` is what makes a copy of the wrapper an error. */
export function onDestroy<T>(this x: Isolated<T>): void {}

/**
 * Wraps a value nothing else names. The checker refuses an argument it cannot prove
 * unshared: a parameter, a module binding, a local that was also stored elsewhere,
 * or a call that may keep an alias. Pass a fresh value or `move` a local binding.
 */
@builtin("Isolate")
export function isolate<T>(sink value: T): Isolated<T> {
	return { value };
}

/** Moves the value out; the wrapper is consumed. */
export function extract<T>(sink iso: Isolated<T>): T {
	return iso.value;
}
