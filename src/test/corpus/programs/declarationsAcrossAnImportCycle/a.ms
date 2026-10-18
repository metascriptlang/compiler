import { tagB, makeCA, baseB } from "./b";

export const TAG_A = "A";
export let COUNT_A = 3;

export class CA {
	v: number;
	constructor(v: number) { this.v = v; }
	next() { return this.v + 3; }
	label() { return `c${this.v}`; }
}

export function useB(): string { return tagB(); }
export function viaB(): number { return makeCA().v; }
export function twice() { return baseB() * 2; }
