import { fromA, counter } from "./a";
function readFrom(): string {
	try {
		return fromA;
	} catch (e) {
		return "caught";
	}
}
function readCounter(): string {
	try {
		return String(counter);
	} catch (e) {
		return "caught";
	}
}
export function seenByB(): string { return `${readFrom()} ${readCounter()}`; }
console.log(`b init: ${readFrom()} ${readCounter()}`);
