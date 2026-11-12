import { Computation } from "./types";
import { getOwner, createOwner, disposeNode, disposeChildren } from "./runtime";
import { runWithOwner } from "./owner";
import { createMemo } from "./memo";
import { accessor, Accessor, Signal } from "./signal";

enum MapMode { Identity, Keyed, Position }

class IndexCell {
	pos: number;
	sig: Signal<number> | null;

	constructor(pos: number) {
		this.pos = pos;
		this.sig = null;
	}

	read(): number {
		if (this.sig === null) { this.sig = new Signal<number>(this.pos, null, true); }
		return (this.sig as Signal<number>).get();
	}

	write(next: number): void {
		this.pos = next;
		if (this.sig !== null) { (this.sig as Signal<number>).set(next); }
	}
}

const noIndex: Accessor<number> = accessor((): number => {
	throw new Error("mapArray: this row has no index accessor: a position-keyed row receives its index as a number, and a row emitted as not reading its index never gets one");
});

function disposeAll(nodes: Computation[]): void {
	for (const n of nodes) { disposeNode(n); }
}

export function mapArray<T, U>(
	list: () => T[],
	mapFn: (item: T, index: Accessor<number>) => U,
	fallback: (() => U) | null = null,
	usesIndex: boolean = true,
): Accessor<U[]> {
	return mapRows<T, T, U>(
		list,
		MapMode.Identity,
		usesIndex,
		(items: T[]): T[] => items.slice(0, items.length),
		(item: T, pos: number, cell: Signal<T> | null, index: Accessor<number>): U => mapFn(item, index),
		fallback,
	);
}

export function mapArrayKeyedBy<T, K, U>(
	list: () => T[],
	keyOf: (item: T) => K,
	mapFn: (item: Accessor<T>, index: Accessor<number>) => U,
	fallback: (() => U) | null = null,
	usesIndex: boolean = true,
): Accessor<U[]> {
	return mapRows<T, K, U>(
		list,
		MapMode.Keyed,
		usesIndex,
		(items: T[]): K[] => {
			const ks: K[] = new Array(items.length);
			for (let j = 0; j < items.length; j += 1) { ks[j] = keyOf(items[j]); }
			return ks;
		},
		(item: T, pos: number, cell: Signal<T> | null, index: Accessor<number>): U => {
			const c = cell as Signal<T>;
			return mapFn(accessor((): T => c.get()), index);
		},
		fallback,
	);
}

export function mapArrayByPosition<T, U>(
	list: () => T[],
	mapFn: (item: Accessor<T>, index: number) => U,
	fallback: (() => U) | null = null,
): Accessor<U[]> {
	return mapRows<T, number, U>(
		list,
		MapMode.Position,
		false,
		(items: T[]): number[] => [],
		(item: T, pos: number, cell: Signal<T> | null, index: Accessor<number>): U => {
			const c = cell as Signal<T>;
			return mapFn(accessor((): T => c.get()), pos);
		},
		fallback,
	);
}

const smallMoveMinWindow = 64;
const smallMoveMaxDisplaced = 32;
const smallMoveCompareBudget = 256;

let smallMoveCount = 0;

export function smallMoveHits(): number {
	return smallMoveCount;
}

class SmallMove<U> {
	mapped: U[];
	nodes: Computation[];
	leavers: Computation[];

	constructor(mapped: U[], nodes: Computation[], leavers: Computation[]) {
		this.mapped = mapped;
		this.nodes = nodes;
		this.leavers = leavers;
	}
}

function smallMove<K, U>(
	oldKeys: K[],
	oldLen: number,
	newKeys: K[],
	newLen: number,
	start: number,
	end: number,
	newEnd: number,
	oldMapped: U[],
	oldNodes: Computation[],
): SmallMove<U> | null {
	const mid = start + Math.floor((newEnd - start) / 2);
	const probeHi = Math.min(end, mid + smallMoveMaxDisplaced);
	let at = Math.max(start, mid - smallMoveMaxDisplaced);
	while (at <= probeHi && oldKeys[at] !== newKeys[mid]) { at += 1; }
	if (at > probeHi) { return null; }

	const oldEnd = oldLen - 1;
	const lastNew = newLen - 1;
	const srcPos: number[] = [];
	const dstPos: number[] = [];
	const runs: number[] = [];
	let budget: number = smallMoveCompareBudget;
	let i = start;
	let j = start;
	let inRun = false;
	while (i <= oldEnd && j <= lastNew) {
		const oldKey = oldKeys[i];
		const newKey = newKeys[j];
		if (oldKey === newKey) {
			if (!inRun) {
				runs.push(i);
				runs.push(j);
				runs.push(0);
				inRun = true;
			}
			runs[runs.length - 1] += 1;
			i += 1;
			j += 1;
			continue;
		}
		inRun = false;
		let del: number = -1;
		let lim = Math.min(Math.min(smallMoveMaxDisplaced - srcPos.length, oldEnd - i), budget);
		for (let a = 1; a <= lim; a += 1) {
			if (oldKeys[i + a] === newKey) { del = a; break; }
		}
		budget -= del === -1 ? lim : del;
		let ins: number = -1;
		lim = Math.min(Math.min(smallMoveMaxDisplaced - dstPos.length, lastNew - j), budget);
		for (let a = 1; a <= lim; a += 1) {
			if (newKeys[j + a] === oldKey) { ins = a; break; }
		}
		budget -= ins === -1 ? lim : ins;
		if (del !== -1 && (ins === -1 || del <= ins)) {
			for (let a = 0; a < del; a += 1) { srcPos.push(i); i += 1; }
			continue;
		}
		if (ins !== -1) {
			for (let a = 0; a < ins; a += 1) { dstPos.push(j); j += 1; }
			continue;
		}
		if (budget <= 0 || srcPos.length === smallMoveMaxDisplaced || dstPos.length === smallMoveMaxDisplaced) { return null; }
		srcPos.push(i);
		dstPos.push(j);
		i += 1;
		j += 1;
	}
	while (i <= oldEnd) {
		if (srcPos.length === smallMoveMaxDisplaced) { return null; }
		srcPos.push(i);
		i += 1;
	}
	while (j <= lastNew) {
		if (dstPos.length === smallMoveMaxDisplaced) { return null; }
		dstPos.push(j);
		j += 1;
	}

	const consumed: boolean[] = [];
	for (let a = 0; a < srcPos.length; a += 1) { consumed.push(false); }
	const pairedSrc: number[] = [];
	for (let b = 0; b < dstPos.length; b += 1) {
		const want = newKeys[dstPos[b]];
		let found: number = -1;
		for (let a = 0; a < srcPos.length; a += 1) {
			if (!consumed[a] && oldKeys[srcPos[a]] === want) { found = a; break; }
		}
		if (found === -1) { return null; }
		consumed[found] = true;
		pairedSrc.push(found);
	}
	for (let a = 0; a < srcPos.length; a += 1) {
		const displaced = oldKeys[srcPos[a]];
		for (let r = 0; r < runs.length; r += 3) {
			const runEnd = runs[r] + runs[r + 2];
			for (let p = runs[r]; p < runEnd; p += 1) {
				if (oldKeys[p] === displaced) { return null; }
			}
		}
	}

	smallMoveCount += 1;
	const mapped = oldMapped.slice(0, newLen);
	const nodes = oldNodes.slice(0, newLen);
	for (let r = 0; r < runs.length; r += 3) {
		if (runs[r] === runs[r + 1]) { continue; }
		for (let a = 0; a < runs[r + 2]; a += 1) {
			mapped[runs[r + 1] + a] = oldMapped[runs[r] + a];
			nodes[runs[r + 1] + a] = oldNodes[runs[r] + a];
		}
	}
	for (let b = 0; b < dstPos.length; b += 1) {
		mapped[dstPos[b]] = oldMapped[srcPos[pairedSrc[b]]];
		nodes[dstPos[b]] = oldNodes[srcPos[pairedSrc[b]]];
	}
	const leavers: Computation[] = [];
	for (let a = 0; a < srcPos.length; a += 1) {
		if (!consumed[a]) { leavers.push(oldNodes[srcPos[a]]); }
	}
	return new SmallMove<U>(mapped, nodes, leavers);
}

function mapRows<T, K, U>(
	list: () => T[],
	mode: MapMode,
	usesIndex: boolean,
	keysOf: (items: T[]) => K[],
	make: (item: T, pos: number, cell: Signal<T> | null, index: Accessor<number>) => U,
	fallback: (() => U) | null,
): Accessor<U[]> {
	const owner = createOwner();
	const hasKeys = mode !== MapMode.Position;
	const hasCells = mode !== MapMode.Identity;
	const hasIdx = mode !== MapMode.Position && usesIndex;
	let keys: K[] = [];
	let mapped: U[] = [];
	let nodes: Computation[] = [];
	let cells: Signal<T>[] = [];
	let idxs: IndexCell[] = [];
	let len = 0;
	let fbNode: Computation | null = null;

	function makeRowInto(
		item: T,
		pos: number,
		mapStore: U[],
		nodeStore: Computation[],
		cellStore: Signal<T>[],
		idxStore: IndexCell[],
		fresh: Computation[],
	): void {
		const node = createOwner();
		nodeStore[pos] = node;
		fresh.push(node);
		mapStore[pos] = runWithOwner<U>(node, (): U => {
			let cell: Signal<T> | null = null;
			if (hasCells) {
				const c = new Signal<T>(item, null, true);
				cellStore[pos] = c;
				cell = c;
			}
			let index: Accessor<number> = noIndex;
			if (hasIdx) {
				const ic = new IndexCell(pos);
				idxStore[pos] = ic;
				index = accessor((): number => ic.read());
			}
			return make(item, pos, cell, index);
		});
	}

	function dropFallback(): void {
		if (fbNode !== null) { disposeNode(fbNode as Computation); }
		fbNode = null;
	}

	return createMemo<U[]>((): U[] => {
		owner.parentComputed = getOwner();
		const newItems = list();
		const newLen = newItems.length;
		return runWithOwner<U[]>(owner, (): U[] => {
			if (newLen === 0) {
				if (len !== 0) {
					keys = [];
					mapped = [];
					nodes = [];
					cells = [];
					idxs = [];
					len = 0;
					disposeChildren(owner, false);
				}
				if (fallback !== null && fbNode === null) {
					const fb = fallback as () => U;
					const node = createOwner();
					let row: U;
					try {
						row = runWithOwner<U>(node, fb);
					} catch (e) {
						disposeNode(node);
						throw e;
					}
					fbNode = node;
					const shown: U[] = [];
					shown.push(row);
					mapped = shown;
				}
				return mapped;
			}

			const newKeys = keysOf(newItems);

			if (len === 0) {
				const firstMapped: U[] = new Array(newLen);
				const firstNodes: Computation[] = new Array(newLen);
				const firstCells: Signal<T>[] = new Array(hasCells ? newLen : 0);
				const firstIdxs: IndexCell[] = new Array(hasIdx ? newLen : 0);
				const fresh: Computation[] = [];
				try {
					for (let j = 0; j < newLen; j += 1) {
						makeRowInto(newItems[j], j, firstMapped, firstNodes, firstCells, firstIdxs, fresh);
					}
				} catch (e) {
					disposeAll(fresh);
					throw e;
				}
				dropFallback();
				mapped = firstMapped;
				nodes = firstNodes;
				cells = firstCells;
				idxs = firstIdxs;
				keys = newKeys;
				len = newLen;
				return mapped;
			}

			let start = 0;
			const minLen = len < newLen ? len : newLen;
			while (start < minLen && (!hasKeys || keys[start] === newKeys[start])) {
				if (hasCells) { cells[start].set(newItems[start]); }
				start += 1;
			}

			let end = len - 1;
			let newEnd = newLen - 1;
			while (hasKeys && end >= start && newEnd >= start && keys[end] === newKeys[newEnd]) {
				end -= 1;
				newEnd -= 1;
			}

			if (start === newLen && len === newLen) {
				keys = newKeys;
				return mapped;
			}

			if (!hasCells && !hasIdx && newLen <= len && end - start > smallMoveMinWindow) {
				const moved = smallMove<K, U>(keys, len, newKeys, newLen, start, end, newEnd, mapped, nodes);
				if (moved !== null) {
					const done = moved as SmallMove<U>;
					mapped = done.mapped;
					nodes = done.nodes;
					keys = newKeys;
					len = newLen;
					disposeAll(done.leavers);
					return mapped;
				}
			}

			const dif = newLen - len;
			const temp: U[] = new Array(newLen);
			const tempFilled: boolean[] = new Array(newLen);
			const tempNodes: Computation[] = new Array(newLen);
			const tempCells: Signal<T>[] = new Array(hasCells ? newLen : 0);
			const tempIdxs: IndexCell[] = new Array(hasIdx ? newLen : 0);
			for (let k = 0; k < newLen; k += 1) { tempFilled[k] = false; }

			const newIndices = new Map<K, number>();
			const newIndicesNext: number[] = new Array(newEnd + 1);
			if (hasKeys) {
				for (let j = newEnd; j >= start; j -= 1) {
					const k = newKeys[j];
					newIndicesNext[j] = newIndices.has(k) ? (newIndices.get(k) as number) : -1;
					newIndices.set(k, j);
				}
			}

			const removed: Computation[] = [];
			for (let i = start; i <= end; i += 1) {
				if (hasKeys) {
					const k = keys[i];
					if (newIndices.has(k)) {
						const j = newIndices.get(k) as number;
						if (j !== -1) {
							temp[j] = mapped[i];
							tempFilled[j] = true;
							tempNodes[j] = nodes[i];
							if (hasCells) { tempCells[j] = cells[i]; }
							if (hasIdx) { tempIdxs[j] = idxs[i]; }
							newIndices.set(k, newIndicesNext[j]);
							continue;
						}
					}
				}
				removed.push(nodes[i]);
			}

			const fresh: Computation[] = [];
			try {
				for (let j = start; j <= newEnd; j += 1) {
					if (tempFilled[j]) { continue; }
					makeRowInto(newItems[j], j, temp, tempNodes, tempCells, tempIdxs, fresh);
				}
			} catch (e) {
				disposeAll(fresh);
				throw e;
			}

			for (let i = 0; i < start; i += 1) {
				temp[i] = mapped[i];
				tempNodes[i] = nodes[i];
				if (hasCells) { tempCells[i] = cells[i]; }
				if (hasIdx) { tempIdxs[i] = idxs[i]; }
			}
			for (let j = start; j <= newEnd; j += 1) {
				if (hasCells) { tempCells[j].set(newItems[j]); }
				if (hasIdx) { tempIdxs[j].write(j); }
			}
			for (let j = newEnd + 1; j < newLen; j += 1) {
				temp[j] = mapped[j - dif];
				tempNodes[j] = nodes[j - dif];
				if (hasCells) {
					tempCells[j] = cells[j - dif];
					tempCells[j].set(newItems[j]);
				}
				if (hasIdx) {
					tempIdxs[j] = idxs[j - dif];
					if (dif !== 0) { tempIdxs[j].write(j); }
				}
			}

			mapped = temp;
			nodes = tempNodes;
			cells = tempCells;
			idxs = tempIdxs;
			keys = newKeys;
			len = newLen;
			disposeAll(removed);
			return mapped;
		});
	});
}

export function repeat<U>(
	count: () => number,
	mapFn: (index: number) => U,
	from: (() => number) | null = null,
	fallback: (() => U) | null = null,
): Accessor<U[]> {
	const owner = createOwner();
	let mapped: U[] = [];
	let nodes: Computation[] = [];
	let offset: int32 = 0;
	let len: int32 = 0;
	let fbNode: Computation | null = null;

	function dropFallback(): void {
		if (fbNode !== null) { disposeNode(fbNode as Computation); }
		fbNode = null;
	}

	return createMemo<U[]>((): U[] => {
		owner.parentComputed = getOwner();
		const wanted = count();
		const origin = from === null ? 0 : (from as () => number)();
		if (wanted < 0 || Math.floor(wanted) !== wanted || wanted > 2147483647) {
			throw new Error("Repeat: count must be a non-negative integer below 2^31, got " + wanted.toString());
		}
		if (Math.floor(origin) !== origin || origin < -2147483648 || origin > 2147483647) {
			throw new Error("Repeat: from must be an integer within int32, got " + origin.toString());
		}
		const newLen = wanted as int32;
		const start = origin as int32;
		return runWithOwner<U[]>(owner, (): U[] => {
			if (newLen === 0) {
				if (len !== 0) {
					mapped = [];
					nodes = [];
					len = 0;
					offset = 0;
					disposeChildren(owner, false);
				}
				if (fallback !== null && fbNode === null) {
					const fb = fallback as () => U;
					const node = createOwner();
					let row: U;
					try {
						row = runWithOwner<U>(node, fb);
					} catch (e) {
						disposeNode(node);
						throw e;
					}
					fbNode = node;
					const shown: U[] = [];
					shown.push(row);
					mapped = shown;
				}
				return mapped;
			}

			const to = start + newLen;
			const prevTo = offset + len;
			const keepStart = start > offset ? start : offset;
			const keepEnd = to < prevTo ? to : prevTo;

			const next: U[] = new Array(newLen);
			const nextNodes: Computation[] = new Array(newLen);
			for (let i = keepStart; i < keepEnd; i += 1) {
				next[i - start] = mapped[i - offset];
				nextNodes[i - start] = nodes[i - offset];
			}
			const fresh: Computation[] = [];
			try {
				for (let i = start; i < to; i += 1) {
					if (i >= keepStart && i < keepEnd) { continue; }
					const node = createOwner();
					nextNodes[i - start] = node;
					fresh.push(node);
					next[i - start] = runWithOwner<U>(node, (): U => mapFn(i));
				}
			} catch (e) {
				disposeAll(fresh);
				throw e;
			}

			if (len === 0) {
				dropFallback();
			} else {
				for (let i = offset; i < prevTo; i += 1) {
					if (i < start || i >= to) { disposeNode(nodes[i - offset]); }
				}
			}
			mapped = next;
			nodes = nextNodes;
			offset = start;
			len = newLen;
			return mapped;
		});
	});
}
