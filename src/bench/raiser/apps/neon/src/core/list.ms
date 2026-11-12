import { Signal } from "./signal";

export enum ListOpKind { Insert, Move, Remove, Set }

export interface ListOp<T> {
	kind: ListOpKind;
	a: number;
	b: number;
	v: T;
}

export interface ListQueue<T> {
	ops: ListOp<T>[];
	reset: boolean;
}

export function matchByIds<K>(oldIds: K[], newIds: K[], out: number[]): void {
	const byId = new Map<K, number>();
	for (let i = 0; i < oldIds.length; i += 1) {
		const k = oldIds[i];
		if (byId.has(k)) { continue; }
		byId.set(k, i);
	}
	for (let j = 0; j < newIds.length; j += 1) {
		const k = newIds[j];
		const at = byId.get(k);
		if (at === null) {
			out[j] = -1;
			continue;
		}
		out[j] = at;
		byId.set(k, -1);
	}
}

export class List<T> {
	private items: T[];
	private queues: ListQueue<T>[];
	private tick: number;
	private version: Signal<number>;
	private identityFromReplaceAll: ((oldItems: T[], newItems: T[], out: number[]) => void) | null;

	constructor(initial: T[]) {
		this.items = initial.slice(0, initial.length);
		this.queues = [];
		this.tick = 0;
		this.version = new Signal<number>(0);
		this.identityFromReplaceAll = null;
	}

	read(): T[] {
		this.version.get();
		return this.items;
	}

	length(): number {
		this.version.get();
		return this.items.length;
	}

	at(i: number): T {
		this.version.get();
		this.bounds(i, this.items.length, "at");
		return this.items[i];
	}

	attach(): ListQueue<T> {
		const q: ListQueue<T> = { ops: [], reset: false };
		this.queues.push(q);
		return q;
	}

	detach(q: ListQueue<T>): void {
		const n = this.queues.length;
		let at = -1;
		for (let i = 0; i < n; i += 1) {
			if (this.queues[i] === q) { at = i; }
		}
		if (at < 0) { throw new Error("List.detach: this queue is not attached to this list"); }
		for (let i = at; i < n - 1; i += 1) { this.queues[i] = this.queues[i + 1]; }
		this.queues.pop();
	}

	push(v: T): void {
		const i = this.items.length;
		this.items.push(v);
		this.emit({ kind: ListOpKind.Insert, a: i, b: -1, v: v });
	}

	insert(i: number, v: T): void {
		const n = this.items.length;
		if (i < 0 || i > n) {
			throw new Error("List.insert: index " + i.toString() + " is outside 0.." + n.toString());
		}
		this.items.push(v);
		for (let j = n; j > i; j -= 1) { this.items[j] = this.items[j - 1]; }
		this.items[i] = v;
		this.emit({ kind: ListOpKind.Insert, a: i, b: -1, v: v });
	}

	move(from: number, to: number): void {
		const n = this.items.length;
		this.bounds(from, n, "move");
		this.bounds(to, n, "move");
		if (from === to) { return; }
		const it = this.items[from];
		if (from < to) {
			for (let j = from; j < to; j += 1) { this.items[j] = this.items[j + 1]; }
		} else {
			for (let j = from; j > to; j -= 1) { this.items[j] = this.items[j - 1]; }
		}
		this.items[to] = it;
		this.emit({ kind: ListOpKind.Move, a: from, b: to, v: it });
	}

	remove(i: number): void {
		const n = this.items.length;
		this.bounds(i, n, "remove");
		const gone = this.items[i];
		for (let j = i; j < n - 1; j += 1) { this.items[j] = this.items[j + 1]; }
		this.items.pop();
		this.emit({ kind: ListOpKind.Remove, a: i, b: -1, v: gone });
	}

	set(i: number, v: T): void {
		this.bounds(i, this.items.length, "set");
		this.items[i] = v;
		this.emit({ kind: ListOpKind.Set, a: i, b: -1, v: v });
	}

	replaceAll(next: T[]): void {
		if (this.identityFromReplaceAll === null) {
			this.identityFromReplaceAll = (oldItems: T[], newItems: T[], out: number[]): void => {
				matchByIds<T>(oldItems, newItems, out);
			};
		}
		this.items = next.slice(0, next.length);
		for (const q of this.queues) {
			q.ops = [];
			q.reset = true;
		}
		this.tick = this.tick + 1;
		this.version.set(this.tick);
	}

	matchByIdentity(oldItems: T[], newItems: T[], out: number[]): void {
		const match = this.identityFromReplaceAll;
		if (match === null) {
			throw new Error("List.matchByIdentity: only a list that took a replaceAll"
				+ " matches its items by identity");
		}
		(match as (oldItems: T[], newItems: T[], out: number[]) => void)(oldItems, newItems, out);
	}

	private bounds(i: number, n: number, who: string): void {
		if (i < 0 || i >= n) {
			throw new Error("List." + who + ": index " + i.toString() + " is outside 0.." + (n - 1).toString());
		}
	}

	private emit(op: ListOp<T>): void {
		for (const q of this.queues) { q.ops.push(op); }
		this.tick = this.tick + 1;
		this.version.set(this.tick);
	}
}

export function createList<T>(initial: T[]): List<T> {
	return new List<T>(initial);
}
