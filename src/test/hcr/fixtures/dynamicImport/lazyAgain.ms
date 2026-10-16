import { Note } from "./note";
import { label } from "./dep";

console.log("DYN lazy body g3");
export const held = new Note("lazy");
export const ready: string = `g3 ${label}`;
export function version(): string { return "g3"; }

@afterReload
function resumed(): void {
	console.log("DYN resumed lazy g3");
}
