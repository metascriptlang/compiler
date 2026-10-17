import { fromB } from "./b";
console.log("a body");
export function fromA(): string { return "a"; }
export const seen: string = fromB();
