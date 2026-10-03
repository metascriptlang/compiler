import { Inner } from "./inner";

export function work(): number {
	const shared = new Inner();
	shared.v = 2;
	const get = (): number => shared.v;
	return get();
}

export function outer(): number {
	function work(): number {
		const shared = new Inner();
		shared.v = 11;
		const get = (): number => shared.v;
		return get();
	}
	return work();
}

export function nested(): number {
	const shared = new Inner();
	shared.v = 7;
	const mid = (): number => {
		const shared2 = new Inner();
		shared2.v = 8;
		const leaf = (): number => shared.v + shared2.v;
		return leaf();
	};
	return mid();
}
