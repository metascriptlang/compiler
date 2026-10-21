// An interface has no run-time identity, so `shape as Circle` down an extends chain is refused
// (checker3pass interfaceDownConversion). These are the replacements the refusal names: a class
// tested with instanceof or converted with a checked `as`, and a discriminated union.
// @stdout: ci=3 st=4 sub=3 sq=-1 cast=3 round=5 square=-1 up=ci some=3

interface Shape { name: string; }
interface Circle extends Shape { radius: number; }
class Ci implements Circle { name: string = "ci"; radius: number = 3; }
class St { name: string = "st"; radius: number = 4; }
class Sub extends Ci { more: number = 1; }
class Sq implements Shape { name: string = "sq"; side: number = 2; }

function radiusOf(s: Shape): number {
	if (s instanceof Ci) return s.radius;
	if (s instanceof St) return s.radius;
	return -1;
}

interface Round { kind: "round"; name: string; radius: number; }
interface Square { kind: "square"; name: string; side: number; }
type Figure = Round | Square;

function figureRadius(f: Figure): number {
	if (f.kind == "round") return f.radius;
	return -1;
}

const held: Shape = new Ci();
const circle: Circle = new Ci();
const some: Circle | null = new Ci();
const round: Figure = { kind: "round", name: "r", radius: 5 };
const square: Figure = { kind: "square", name: "q", side: 1 };
console.log("ci=" + radiusOf(new Ci()) + " st=" + radiusOf(new St()) + " sub=" + radiusOf(new Sub())
	+ " sq=" + radiusOf(new Sq()) + " cast=" + (held as Ci).radius
	+ " round=" + figureRadius(round) + " square=" + figureRadius(square)
	+ " up=" + (circle as Shape).name + " some=" + (some as Circle).radius);
