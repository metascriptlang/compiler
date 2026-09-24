import { fb } from "./b";
export function fa(n: number): number { return n <= 0 ? 0 : fb(n - 1) + 1; }
