import { TAG_A, COUNT_A, CA, twice } from "./a";

export function tagB(): string { return TAG_A + "b"; }
export function makeCA(): CA { return new CA(7); }

export function half() {
	const t = twice();
	const s: number = t;
	return s / 21;
}

export function label() { return TAG_A.toLowerCase() + "b" + `${COUNT_A}`; }

export function counted() {
	const c = new CA(4);
	const k = c.next();
	const n: number = k;
	return c.label() + ":" + `${n + 3}`;
}

export function baseB() { return 21; }
