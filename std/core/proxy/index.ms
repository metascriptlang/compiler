// Proxy — member reads and writes of a target routed through a handler's traps.
//
// `Proxy<T, H>` is a distinct of the cell, so it shows no fields: the checker
// rewrites `p.key` into the handler's `get` when H declares one and into the
// target's field otherwise, and `p.key = v` the same way with `set`
// (src/checker/proxy.ms, docs/LANG.md "Proxy").

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
