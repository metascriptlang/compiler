import { tag } from "./hub";

export function viaHub(): string { return `${tag(5)} ${"z".tag()}`; }
