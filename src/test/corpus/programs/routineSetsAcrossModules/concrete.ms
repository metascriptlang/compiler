import { describe } from "./shapes";
export function describe(this b: boolean): string { return `boolean ${b}`; }
export function viaConcrete(n: number, s: string, b: boolean): string { return `${n.describe()} | ${s.describe()} | ${b.describe()}`; }
