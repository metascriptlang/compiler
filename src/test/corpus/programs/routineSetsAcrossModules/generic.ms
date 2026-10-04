import { describe } from "./shapes";
export function describe<T>(this x: T): string { return "any"; }
export function viaGeneric(n: number, s: string, b: boolean): string { return `${n.describe()} | ${s.describe()} | ${b.describe()}`; }
