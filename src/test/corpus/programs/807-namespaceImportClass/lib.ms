export enum Color { Red, Green, Blue }
export function f(n: number): number { return n * 2; }
export class K { v: number; constructor(v: number) { this.v = v; } get(): number { return this.v; } }
export const LIMIT = 42;
export function twiceF(n: number): number { return f(f(n)); }
export function id<T>(x: T): T { return x; }
