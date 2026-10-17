import { Note } from "./note";
import { label } from "./dep";

console.log("DYN lazy body g1");
export const held = new Note("lazy");
export const ready: string = `g1 ${label}`;
export function version(): string { return "g1"; }

@afterReload
function resumed(): void {
	console.log("DYN resumed lazy g1");
}
