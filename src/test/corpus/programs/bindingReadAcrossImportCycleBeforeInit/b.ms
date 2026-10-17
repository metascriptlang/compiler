import { fromA } from "./a";
export function readB(): string { return fromA; }
function early(): string {
	try {
		return readB();
	} catch (e) {
		console.log(`b init: caught ${(e as Error).message}`);
		return "";
	}
}
export const seenAtInit: string = early();
