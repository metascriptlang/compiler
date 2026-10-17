import { fromA } from "./a";
console.log("b start");
await sleepAsync(1);
console.log("b end");
export function fromB(): string { return "b sees " + fromA(); }
