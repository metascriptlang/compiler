import { createInterpreter, evalModule, selectRoutine, callRoutine, implementRoutine, Interpreter, Routine, RaiserValue, boxInt, boxFloat, boxVoid, unboxInt, unboxFloat } from "../../src/embed/index";
import { argv, exit } from "std/process";

const BALLS: int32 = 1000;
const FRAMES: int32 = 600;
const CALLS: int32 = 1000000;

function routine(interp: Interpreter, name: string): Routine {
	const selected = selectRoutine(interp, name);
	if (!selected.ok) {
		console.log(selected.error);
		exit(1);
	}
	return selected.value;
}

function call(interp: Interpreter, r: Routine, args: RaiserValue[]): RaiserValue {
	const result = callRoutine(interp, r, args);
	if (!result.ok) {
		console.log(result.error);
		exit(1);
	}
	return result.value;
}

function rounded(x: number, scale: number): number {
	return Math.round(x * scale) / scale;
}

const root = argv.length > 1 ? argv[1] : ".";
const created = createInterpreter(root);
if (!created.ok) {
	console.log(created.error);
	exit(1);
}
const interp = created.value;

let spawnedCount = 0;
implementRoutine("game.spawned", (args: RaiserValue[]): RaiserValue => {
	spawnedCount += 1;
	return boxVoid();
});

const script = argv.length > 2 ? argv[2] : "examples/embedGameLoop/game.ms";
const t0 = performance.now();
const evaluated = evalModule(interp, script);
if (!evaluated.ok) {
	for (const d of evaluated.error) console.log(`${d.file}:${d.line}:${d.column} ${d.message}`);
	exit(1);
}
console.log(`check + compile + run module: ${Math.round(performance.now() - t0)} ms`);

const balls = unboxInt(call(interp, routine(interp, "start"), [boxInt(BALLS)]));
console.log(`start: ${balls} balls, host saw ${spawnedCount} spawned() calls`);

const update = routine(interp, "update");
const dt = boxFloat(1.0 / 60.0);
const t1 = performance.now();
let frames: int32 = 0;
for (let f: int32 = 0; f < FRAMES; f += 1) frames = unboxInt(call(interp, update, [dt])) as int32;
const perFrame = (performance.now() - t1) / (FRAMES as number);
console.log(`update: ${frames} frames, ${rounded(perFrame, 1000)} ms per frame for ${BALLS} balls, ball 0 at x=${rounded(unboxFloat(call(interp, routine(interp, "ballX"), [boxInt(0)])), 100)}`);

const noop = routine(interp, "noop");
const t2 = performance.now();
for (let i: int32 = 0; i < CALLS; i += 1) call(interp, noop, []);
const perCall = (performance.now() - t2) * 1000000.0 / (CALLS as number);
console.log(`host -> script call: ${rounded(perCall, 10)} ns per call (${CALLS} calls of noop)`);
