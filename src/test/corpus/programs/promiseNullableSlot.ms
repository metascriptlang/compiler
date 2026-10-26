// @stdout: mI mS mP hI hS hP fI fS fP hS2 mapMiss mapHit 1 s 7 true
// note: `Promise<T> | null` is a nullable pointer, so a null test on a slot of that type is a runtime check on every lane: a module variable, a field and a Map.get result, each with ===, !== and ==, the lazy-init shape and the cast back to the promise.

class Pet {
	n: int32 = 7;
}

async function mkI(): Promise<int32> { return 1; }
async function mkS(): Promise<string> { return "s"; }
async function mkP(): Promise<Pet> { return new Pet(); }

class Slots {
	i: Promise<int32> | null = null;
	s: Promise<string> | null = null;
	p: Promise<Pet> | null = null;
}

const marks: string[] = [];
let modI: Promise<int32> | null = null;
let modS: Promise<string> | null = null;
let modP: Promise<Pet> | null = null;
const slots = new Slots();
const loads: Map<string, Promise<boolean>> = new Map();

function lazyI(): Promise<int32> {
	if (modI === null) { marks.push("mI"); modI = mkI(); } else { marks.push("hI"); }
	return modI as Promise<int32>;
}
function lazyS(): Promise<string> {
	if (modS == null) { marks.push("mS"); modS = mkS(); } else { marks.push("hS"); }
	return modS as Promise<string>;
}
function lazyP(): Promise<Pet> {
	if (modP !== null) { marks.push("hP"); } else { marks.push("mP"); modP = mkP(); }
	return modP as Promise<Pet>;
}

lazyI(); lazyS(); lazyP();
const vi = lazyI();
const vs = lazyS();
const vp = lazyP();

function fieldI(): void {
	if (slots.i === null) { marks.push("fI"); slots.i = mkI(); }
}
function fieldS(): void {
	if (slots.s !== null) { marks.push("hS2"); } else { marks.push("fS"); slots.s = mkS(); }
}
function fieldP(): void {
	if (slots.p == null) { marks.push("fP"); slots.p = mkP(); }
}
fieldI(); fieldS(); fieldP();
fieldI(); fieldS(); fieldP();

const miss = loads.get("a");
if (miss !== null) { marks.push("mapHit?"); } else { marks.push("mapMiss"); }
loads.set("a", Promise.resolve(true));
const hit = loads.get("a");
if (hit !== null) { marks.push("mapHit"); } else { marks.push("mapMiss?"); }

console.log(`${marks.join(" ")} ${await vi} ${await vs} ${(await vp).n} ${await (loads.get("a") as Promise<boolean>)}`);
