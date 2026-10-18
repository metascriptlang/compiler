import { Inner } from "./inner";

export function work(): number {
	const shared = new Inner();
	shared.v = 3;
	const get = (): number => shared.v;
	return get();
}

export function outer(): number {
	function work(): number {
		const shared = new Inner();
		shared.v = 12;
		const get = (): number => shared.v;
		return get();
	}
	return work();
}

export function nested(): number {
	const shared = new Inner();
	shared.v = 9;
	const mid = (): number => {
		const shared2 = new Inner();
		shared2.v = 4;
		const leaf = (): number => shared.v + shared2.v;
		return leaf();
	};
	return mid();
}
