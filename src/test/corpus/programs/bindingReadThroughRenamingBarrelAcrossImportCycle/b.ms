import { renamedA } from "./c";
export function readB(): string { return renamedA; }
function early(): string {
	try {
		return readB();
	} catch (e) {
		console.log("b init: threw before a declared fromA");
		return "";
	}
}
export const seenAtInit: string = early();
