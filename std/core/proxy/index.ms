// Proxy — member reads and writes of a target routed through a handler's traps.
//
// `Proxy<T, H>` is a distinct of the cell, so it shows no fields: the checker
// rewrites `p.key` into the handler's `get` when H declares one and into the
// target's field otherwise, and `p.key = v` the same way with `set`
// (src/checker/proxy.ms, docs/LANG.md "Proxy").

import { isArray } from "std/typetraits";

export class ProxyCell<T, H> {
	target: T;
	handler: H;
	constructor(target: T, handler: H) { this.target = target; this.handler = handler; }
}

export type Proxy<T, H> = distinct ProxyCell<T, H>;

export function newProxy<T, H>(target: T, handler: H): Proxy<T, H> {
	return new ProxyCell<T, H>(target, handler) as Proxy<T, H>;
}

export function proxyTarget<T, H>(p: Proxy<T, H>): T { return (p as ProxyCell<T, H>).target; }

export function proxyHandler<T, H>(p: Proxy<T, H>): H { return (p as ProxyCell<T, H>).handler; }

// Calls `f` with `p`, so a trap call built at the use site reads a receiver with effects once.
export function proxyWith<T, H, R>(p: Proxy<T, H>, f: (p: Proxy<T, H>) => R): R { return f(p); }

// Calls `f` with `p` and `key`, so a compound write evaluates both once.
export function proxyWithKey<T, H, K, R>(p: Proxy<T, H>, key: K, f: (p: Proxy<T, H>, key: K) => R): R { return f(p, key); }

// A `set` or `deleteProperty` trap that returns false fails the write, as in strict-mode JavaScript.
export function proxyChecked<K>(ok: boolean, trap: string, key: K): void {
	if (!ok) throw new Error(`'${trap}' on a Proxy returned false for the key '${key}'`);
}

// ===== Reflect — what each trap does when the handler leaves it out =====

export class Reflect {
	static get<T, K extends keyof T>(target: T, key: K): T[K] { return target[key]; }
	static set<T, K extends keyof T>(target: T, key: K, value: T[K]): boolean {
		when (isArray<T>()) { return arraySet(target, key, value); } else {
			target[key] = value;
			return true;
		}
	}
	static has<T, K extends keyof T>(target: T, key: K): boolean {
		when (isArray<T>()) { return arrayHas(target, key); } else { return true; }
	}
	static deleteProperty<T, K extends keyof T>(target: T, key: K): boolean {
		when (isArray<T>()) { return arrayDelete(target, key); } else { return false; }
	}
}

function holeError(what: string, length: number): never {
	throw new Error(`${what} would leave a hole in an array of length ${length}`);
}

// An index write at the length appends, as JavaScript's [[Set]] does; past it would leave a hole.
function arraySet<E>(target: E[], key: number, value: E): boolean {
	if (key == target.length) target.push(value);
	else if (key > target.length) holeError(`a write at index ${key}`, target.length);
	else target[key] = value;
	return true;
}
// A shorter length cuts the array; a longer one would leave holes.
function arraySet<E>(target: E[], key: "length", value: number): boolean {
	if (value > target.length) holeError(`a length of ${value}`, target.length);
	target.shrink(value as int64);
	return true;
}

function arrayHas<E>(target: E[], key: number): boolean { return key >= 0 && key < target.length; }
function arrayHas<E>(target: E[], key: "length"): boolean { return true; }

// Deleting the last element removes it; any other index would leave a hole.
function arrayDelete<E>(target: E[], key: number): boolean {
	if (key >= target.length) return true;
	if (key != target.length - 1) holeError(`a delete at index ${key}`, target.length);
	target.pop();
	return true;
}
function arrayDelete<E>(target: E[], key: "length"): boolean { return false; }

// ===== Array methods on a Proxy<E[], H>, step by step as the language specification
// defines them for any object, each step through the trap the use site passed =====

export type ProxyLen<E, H> = (p: Proxy<E[], H>) => number;
export type ProxyGet<E, H> = (p: Proxy<E[], H>, key: number) => E;
export type ProxySet<E, H> = (p: Proxy<E[], H>, key: number, value: E) => void;
export type ProxySetLen<E, H> = (p: Proxy<E[], H>, length: number) => void;
export type ProxyHas<E, H> = (p: Proxy<E[], H>, key: number) => boolean;
export type ProxyDelete<E, H> = (p: Proxy<E[], H>, key: number) => void;

export function proxyPush<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, set: ProxySet<E, H>, setLen: ProxySetLen<E, H>, value: E): void {
	const n = len(p);
	set(p, n, value);
	setLen(p, n + 1);
}

export function proxyPop<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, del: ProxyDelete<E, H>, setLen: ProxySetLen<E, H>): E {
	const n = len(p);
	const last = get(p, n - 1);
	del(p, n - 1);
	setLen(p, n - 1);
	return last;
}

// The element at `from` moves to `to`; a missing one deletes `to`.
function moveElement<E, H>(p: Proxy<E[], H>, from: number, to: number, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>, del: ProxyDelete<E, H>): void {
	if (has(p, from)) set(p, to, get(p, from));
	else del(p, to);
}

export function proxyShift<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>, del: ProxyDelete<E, H>, setLen: ProxySetLen<E, H>): E {
	const n = len(p);
	const first = get(p, 0);
	for (let k = 1; k < n; k += 1) moveElement(p, k, k - 1, get, set, has, del);
	del(p, n - 1);
	setLen(p, n - 1);
	return first;
}

// The plain array's splice: a start outside the array or a count below one changes nothing.
export function proxySplice<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>, del: ProxyDelete<E, H>, setLen: ProxySetLen<E, H>, start: number, deleteCount: number): void {
	const n = len(p);
	if (start < 0 || start >= n || deleteCount <= 0) return;
	const count = start + deleteCount > n ? n - start : deleteCount;
	for (let k = start; k < start + count; k += 1) {
		if (has(p, k)) get(p, k);
	}
	for (let k = start; k < n - count; k += 1) moveElement(p, k + count, k, get, set, has, del);
	for (let k = n; k > n - count; k -= 1) del(p, k - 1);
	setLen(p, n - count);
}

// A missing element on either side would leave a hole where the specification moves one.
export function proxyReverse<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>): void {
	const n = len(p);
	for (let lower = 0; lower < Math.floor(n / 2); lower += 1) {
		const upper = n - lower - 1;
		if (!has(p, lower)) holeError(`reverse at index ${lower}`, n);
		const lowerValue = get(p, lower);
		if (!has(p, upper)) holeError(`reverse at index ${upper}`, n);
		const upperValue = get(p, upper);
		set(p, lower, upperValue);
		set(p, upper, lowerValue);
	}
}

export function proxyFill<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, set: ProxySet<E, H>, value: E): void {
	const n = len(p);
	for (let k = 0; k < n; k += 1) set(p, k, value);
}

// The elements are read out, sorted as a plain array, and written back in order.
function sortedItems<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>): E[] {
	const n = len(p);
	const items: E[] = [];
	for (let k = 0; k < n; k += 1) {
		if (has(p, k)) items.push(get(p, k));
	}
	return items;
}

function writeBack<E, H>(p: Proxy<E[], H>, items: E[], set: ProxySet<E, H>): void {
	for (let j = 0; j < items.length; j += 1) set(p, j, items[j]);
}

export function proxySort<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>, cmp: (a: E, b: E) => number): void {
	const items = sortedItems(p, len, get, has);
	items.sort(cmp);
	writeBack(p, items, set);
}

export function proxySortDefault<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, set: ProxySet<E, H>, has: ProxyHas<E, H>): void {
	const items = sortedItems(p, len, get, has);
	items.sort();
	writeBack(p, items, set);
}

export function proxyMap<E, H, U>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, fn: (x: E, i: number) => U): U[] {
	const n = len(p);
	const out: U[] = [];
	for (let k = 0; k < n; k += 1) {
		if (!has(p, k)) holeError(`map at index ${k}`, n);
		out.push(fn(get(p, k), k));
	}
	return out;
}

export function proxyFilter<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, fn: (x: E, i: number) => boolean): E[] {
	const n = len(p);
	const out: E[] = [];
	for (let k = 0; k < n; k += 1) {
		if (!has(p, k)) continue;
		const value = get(p, k);
		if (fn(value, k)) out.push(value);
	}
	return out;
}

export function proxySome<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, fn: (x: E, i: number) => boolean): boolean {
	const n = len(p);
	for (let k = 0; k < n; k += 1) {
		if (has(p, k) && fn(get(p, k), k)) return true;
	}
	return false;
}

export function proxyFind<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, fn: (x: E, i: number) => boolean): E | null {
	const n = len(p);
	for (let k = 0; k < n; k += 1) {
		const value = get(p, k);
		if (fn(value, k)) return value;
	}
	return null;
}

export function proxyFindIndex<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, fn: (x: E, i: number) => boolean): number {
	const n = len(p);
	for (let k = 0; k < n; k += 1) {
		if (fn(get(p, k), k)) return k;
	}
	return -1;
}

export function proxyFindLastIndex<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, fn: (x: E, i: number) => boolean): number {
	for (let k = len(p) - 1; k >= 0; k -= 1) {
		if (fn(get(p, k), k)) return k;
	}
	return -1;
}

export function proxyIndexOf<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, value: E): number {
	const n = len(p);
	for (let k = 0; k < n; k += 1) {
		if (has(p, k) && get(p, k) === value) return k;
	}
	return -1;
}

export function proxyLastIndexOf<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, value: E, fromIndex: number = -1): number {
	const n = len(p);
	for (let k = fromIndex < 0 ? n + fromIndex : Math.min(fromIndex, n - 1); k >= 0; k -= 1) {
		if (has(p, k) && get(p, k) === value) return k;
	}
	return -1;
}

export function proxyIncludes<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, value: E): boolean {
	const n = len(p);
	for (let k = 0; k < n; k += 1) {
		if (get(p, k) === value) return true;
	}
	return false;
}

export function proxyJoin<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, sep: string): string {
	const n = len(p);
	let out = "";
	for (let k = 0; k < n; k += 1) {
		if (k > 0) out = out + sep;
		out = out + `${get(p, k)}`;
	}
	return out;
}

export function proxySlice<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, has: ProxyHas<E, H>, start: number, end: number = 9007199254740991): E[] {
	const n = len(p);
	const from = start < 0 ? Math.max(n + start, 0) : Math.min(start, n);
	const to = end < 0 ? Math.max(n + end, 0) : Math.min(end, n);
	const out: E[] = [];
	for (let k = from; k < to; k += 1) {
		if (has(p, k)) out.push(get(p, k));
	}
	return out;
}

export function proxyAt<E, H>(p: Proxy<E[], H>, len: ProxyLen<E, H>, get: ProxyGet<E, H>, index: number): E {
	const n = len(p);
	const i = Math.trunc(index);
	return get(p, i < 0 && i >= -n ? n + i : i);
}
