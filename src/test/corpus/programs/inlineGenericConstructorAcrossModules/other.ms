import { Holder, Names } from "./lib";

export function fromOther(n: number): string {
	const ints = new Holder<number>([n, n + 1], 2);
	const names = new Names("o", n);
	return `${ints.items.join(",")} ${names.label} ${names.items.join(",")} ${names.length}`;
}
