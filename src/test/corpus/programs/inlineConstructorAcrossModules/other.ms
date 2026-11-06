import { Sized, Store } from "./lib";

export function fromOther(n: number): string {
	const store = new Store();
	store.bytes.push(n);
	store.bytes.push(n);
	const a = new Sized(n);
	const b = new Sized(store);
	return `${a.label} ${a.held} ${b.label} ${b.held} ${b.store === store}`;
}
