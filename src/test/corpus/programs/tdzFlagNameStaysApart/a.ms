import { seenByB } from "./b";
export const fromA: string = "a" + String(1);
export const fromA$init: string = "user";
export let counter: number = 7;
export const counter$init: number = 9;
console.log(`a sees: ${seenByB()}`);
export function show(): string { return `${fromA}:${fromA$init}:${counter}:${counter$init}`; }
