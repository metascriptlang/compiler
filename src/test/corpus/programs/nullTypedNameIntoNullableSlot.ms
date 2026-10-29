// @stdout: class 0 0 0 0 0
// @stdout: number 0 0 0 0
// @stdout: string 0 0 0 0
// @stdout: array 0 0 0 0
// @stdout: pair 0 0 0
// @stdout: shape 0 0 0 0
// @stdout: slot 0 held 1
class T { x: number = 1; }
interface Shape { n: number; }

function isNullClass(a: T | null): number { return a == null ? 0 : 1; }
function isNullShape(a: Shape | null): number { return a == null ? 0 : 1; }
function isNullNumber(a: number | null): number { return a == null ? 0 : 1; }
function isNullString(a: string | null): number { return a == null ? 0 : 1; }
function isNullArray(a: number[] | null): number { return a == null ? 0 : 1; }
function bothNull(a: T | null, b: string | null): number { return (a == null ? 0 : 1) + (b == null ? 0 : 2); }

const moduleNull = null;

function nothing() {
	const local = null;
	return local;
}

function main(): void {
	const localConst = null;
	let localLet = null;
	const returned = nothing();
	console.log("class", isNullClass(moduleNull), isNullClass(localConst), isNullClass(localLet), isNullClass(returned), isNullClass(null));
	console.log("number", isNullNumber(moduleNull), isNullNumber(localConst), isNullNumber(localLet), isNullNumber(returned));
	console.log("string", isNullString(moduleNull), isNullString(localConst), isNullString(localLet), isNullString(returned));
	console.log("array", isNullArray(moduleNull), isNullArray(localConst), isNullArray(localLet), isNullArray(returned));
	console.log("pair", bothNull(moduleNull, localConst), bothNull(localLet, returned), bothNull(localConst, null));
	console.log("shape", isNullShape(moduleNull), isNullShape(localConst), isNullShape(localLet), isNullShape(returned));
	let slot: T | null = localConst;
	const empty = isNullClass(slot);
	slot = new T();
	console.log("slot", empty, "held", isNullClass(slot));
}

main();
