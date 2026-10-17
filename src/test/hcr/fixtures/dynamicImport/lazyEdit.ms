import { Note } from "./note";
import { label } from "./dep";

console.log("DYN lazy body g2");
export const held = new Note("lazy");
export const ready: string = `g2 ${label}`;
export function version(): string { return "g2"; }

@afterReload
function resumed(): void {
	console.log("DYN resumed lazy g2");
}
