// A generator resumed from inside its own body throws "Generator is already running" and the
// generator keeps its state: through next, through return, and through an iterator helper callback.
// @stdout: ok
const trace: string[] = [];

function log(s: string): void {
	trace.push(s);
}

const viaNextBox: Iterator<int32>[] = [];
let depth: int32 = 0;

function* viaNext(): Iterator<int32> {
	depth += 1;
	try {
		viaNextBox[0].next();
		log("next no throw");
	} catch (e) {
		log(`next ${(e as Error).message}`);
	}
	yield 1;
	yield 2;
}

viaNextBox.push(viaNext());
log(`a ${viaNextBox[0].next().value}`);
log(`b ${viaNextBox[0].next().value}`);
log(`c ${viaNextBox[0].next().done} depth ${depth}`);

const viaReturnBox: Iterator<int32>[] = [];

function* viaReturn(): Iterator<int32> {
	try {
		const self = viaReturnBox[0];
		if (self.return != null) self.return();
		log("return no throw");
	} catch (e) {
		log(`return ${(e as Error).message}`);
	}
	yield 1;
	yield 2;
}

viaReturnBox.push(viaReturn());
log(`d ${viaReturnBox[0].next().value}`);
log(`e ${viaReturnBox[0].next().value}`);
const closing = viaReturnBox[0];
log(`f ${closing.return != null ? closing.return().done : false}`);
log(`g ${viaReturnBox[0].next().done}`);

let pulls: int32 = 0;
const source: Iterator<int32> = {
	next: () => {
		pulls += 1;
		return { done: false, value: pulls };
	},
	return: () => ({ done: true, value: 0 }),
};
const helperBox: Iterator<int32>[] = [];
let helperDepth: int32 = 0;
helperBox.push(source.map<int32, int32>((x: int32, i: number): int32 => {
	helperDepth += 1;
	if (helperDepth == 1) {
		try {
			helperBox[0].next();
			log("map no throw");
		} catch (e) {
			log(`map ${(e as Error).message}`);
		}
	}
	return x;
}));
log(`h ${helperBox[0].next().value} depth ${helperDepth}`);
log(`i ${helperBox[0].next().value} depth ${helperDepth}`);

const expected: string[] = [
	"next Generator is already running",
	"a 1",
	"b 2",
	"c true depth 1",
	"return Generator is already running",
	"d 1",
	"e 2",
	"f true",
	"g true",
	"map Generator is already running",
	"h 1 depth 1",
	"i 2 depth 2",
];
if (trace.length != expected.length) {
	throw new Error(`trace has ${trace.length} lines, expected ${expected.length}\n${trace.join("\n")}`);
}
for (let i = 0; i < expected.length; i += 1) {
	if (trace[i] != expected[i]) {
		throw new Error(`line ${i}: got "${trace[i]}", expected "${expected[i]}"`);
	}
}
console.log("ok");
