import { Inner } from "./inner";

export function work(): number {
	const shared = new Inner();
	shared.v = 1;
	const get = (): number => shared.v;
	return get();
}

export function outer(): number {
	function work(): number {
		const shared = new Inner();
		shared.v = 10;
		const get = (): number => shared.v;
		return get();
	}
	return work();
}

export function nested(): number {
	const shared = new Inner();
	shared.v = 5;
	const mid = (): number => {
		const shared2 = new Inner();
		shared2.v = 6;
		const leaf = (): number => shared.v + shared2.v;
		return leaf();
	};
	return mid();
}
