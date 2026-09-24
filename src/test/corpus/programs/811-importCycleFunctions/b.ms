import { fa } from "./a";
export function fb(n: number): number { return n <= 0 ? 100 : fa(n - 1) + 10; }
