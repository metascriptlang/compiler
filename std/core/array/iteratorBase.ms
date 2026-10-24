export struct IteratorResult<T> {
	value: T;
	done: boolean;
}

@builtin("Iterator")
export struct Iterator<T> {
	next: () => IteratorResult<T>;
	return: (() => IteratorResult<T>) | null;
}

export function* concat<T>(this typeof Iterator, ...items: Iterator<T>[]): Iterator<T> {
	for (const it of items) {
		for (const x of it) yield x;
	}
}

export type ZipMode = "shortest" | "longest" | "strict";

export interface ZipOptions<T> {
	mode?: ZipMode;
	padding?: T[];
}

function closeAll<T>(iters: Iterator<T>[], open: boolean[], swallow: boolean): void {
	let failure: Error | null = null;
	for (let i = iters.length - 1; i >= 0; i--) {
		if (!open[i]) continue;
		open[i] = false;
		const it = iters[i];
		if (it.return != null) {
			try {
				it.return();
			} catch (e) {
				if (failure == null) failure = e;
			}
		}
	}
	if (!swallow && failure != null) throw failure;
}

function advance<T>(iters: Iterator<T>[], open: boolean[], i: number, out: T[]): boolean {
	try {
		const r = iters[i].next();
		if (!r.done) out.push(r.value);
		return r.done;
	} catch (e) {
		open[i] = false;
		closeAll(iters, open, true);
		throw e;
	}
}

function* zipLazy<T>(iters: Iterator<T>[], mode: ZipMode, padding: T[]): Iterator<T[]> {
	const count = iters.length;
	if (count == 0) return;
	const open: boolean[] = [];
	for (let i = 0; i < count; i++) open.push(true);
	let live = count;
	try {
		while (true) {
			const results: T[] = [];
			for (let i = 0; i < count; i++) {
				if (!open[i]) {
					results.push(padding[i]);
					continue;
				}
				if (!advance(iters, open, i, results)) continue;
				open[i] = false;
				live -= 1;
				match (mode) {
					"shortest" => {
						return;
					}
					"strict" => {
						if (i != 0) {
							closeAll(iters, open, true);
							throw new Error("zip: iterators have different lengths");
						}
						const spare: T[] = [];
						for (let k = 1; k < count; k++) {
							if (!advance(iters, open, k, spare)) {
								closeAll(iters, open, true);
								throw new Error("zip: iterators have different lengths");
							}
							open[k] = false;
						}
						return;
					}
					_ => {
						if (live == 0) return;
						results.push(padding[i]);
					}
				}
			}
			yield results;
		}
	} finally {
		closeAll(iters, open, false);
	}
}

export function zip<T>(
	this typeof Iterator,
	items: Iterator<T>[],
	options?: ZipOptions<T>,
): Iterator<T[]> {
	const mode: ZipMode = options != null && options.mode != null ? options.mode : "shortest";
	let padding: T[] = [];
	if (mode == "longest") {
		if (options == null || options.padding == null || options.padding.length < items.length) {
			const open: boolean[] = [];
			for (let i = 0; i < items.length; i++) open.push(true);
			closeAll(items, open, true);
			throw new Error("zip: mode longest needs one padding value per iterator");
		}
		padding = options.padding;
	}
	return zipLazy(items, mode, padding);
}

export struct Peekable<T> extends Iterator<T> {
	peek: () => T | null;
}

export function toItems<T>(this p: Peekable<T>): Iterator<T> {
	return { next: p.next, return: p.return };
}

export function peekable<T>(this it: Iterator<T>): Peekable<T> {
	const slot: T[] = [];
	let exhausted = false;
	const fill = (): boolean => {
		if (slot.length > 0) return true;
		if (exhausted) return false;
		const r = it.next();
		if (r.done) {
			exhausted = true;
			return false;
		}
		slot.push(r.value);
		return true;
	};
	return {
		next: () => {
			if (slot.length > 0) return { value: slot.pop(), done: false };
			return it.next();
		},
		return: () => {
			if (it.return != null) return it.return();
			return it.next();
		},
		peek: () => (fill() ? slot[0] : null),
	};
}

function lessThan<T>(a: T, b: T): boolean {
	return a < b;
}

export function min<T>(this it: Iterator<T>): T | null {
	const first = it.next();
	if (first.done) return null;
	let best = first.value;
	for (const x of it) {
		if (lessThan(x, best)) best = x;
	}
	return best;
}

export function max<T>(this it: Iterator<T>): T | null {
	const first = it.next();
	if (first.done) return null;
	let best = first.value;
	for (const x of it) {
		if (!lessThan(x, best)) best = x;
	}
	return best;
}
