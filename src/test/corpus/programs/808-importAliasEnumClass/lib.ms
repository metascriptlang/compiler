export enum Color { Red, Green, Blue }
export function f(n: number): number { return n * 2; }
export class K { v: number; constructor(v: number) { this.v = v; } get(): number { return this.v; } }
export let counter: number = 0;
export function bump(): number { counter = counter + 1; return counter; }
