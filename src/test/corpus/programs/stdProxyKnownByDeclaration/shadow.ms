import { Proxy } from "std/core/proxy";

function newProxy(a: number, b: number): number { return a + b; }

export function shadowedNew(): string {
	const p = new Proxy({ a: 4 }, {});
	return `${p.a} ${newProxy(1, 1)}`;
}
