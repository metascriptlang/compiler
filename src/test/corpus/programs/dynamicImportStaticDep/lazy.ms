import { hits, hit } from "./shared";
console.log(`lazy body sees ${hits}`);
hit();
export function report(): string { return `hits ${hits}`; }
