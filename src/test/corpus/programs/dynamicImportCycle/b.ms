import { fromA } from "./a";
console.log("b body");
export function fromB(): string { return "b sees " + fromA(); }
