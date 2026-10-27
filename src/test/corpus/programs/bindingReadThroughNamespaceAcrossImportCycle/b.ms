import * as A from "./a";
export function readB(): string { return A.fromA; }
function early(): string {
	try {
		return readB();
	} catch (e) {
		console.log("b init: threw before a declared fromA");
		return "";
	}
}
export const seenAtInit: string = early();
