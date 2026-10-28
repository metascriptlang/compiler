// @stdout: false|true|false|true
// note: after a null test that does not exit, the join of the narrowed and null halves of a Maybe whose payload is a union is the Maybe again, so a later null test narrows to the payload and its extension methods resolve, with six variants and with an earlier test of the same field.

enum VK { Const, Lin, Pow, Sin, Cos, Random }
struct PV = match (kind: VK) {
	VK.Const => { value: float32 },
	VK.Lin => { start: float32, length: float32 },
	VK.Pow => { start: float32, length: float32, power: float32 },
	VK.Sin => { frequency: float32, amplitude: float32, offset: float32 },
	VK.Cos => { frequency: float32, amplitude: float32, offset: float32 },
	VK.Random => { start: float32, length: float32 },
};
function drawsRandom(this v: PV): boolean { return v.kind == VK.Random; }

struct St { frame: PV | null; n: int32; }

function divergences(this state: St): boolean {
	let found = 0;
	if (state.frame !== null) { found = found + 1; }
	return state.n > 0 || (state.frame !== null && state.frame.drawsRandom());
}

function twice(this state: St): boolean {
	let found = 0;
	if (state.frame !== null) { found = found + 1; }
	if (state.frame !== null) { found = found + 1; }
	return state.frame !== null && state.frame.drawsRandom();
}

const none: St = { frame: null, n: 0 };
const rnd: St = { frame: { kind: VK.Random, start: 0.0, length: 1.0 }, n: 0 };
const lin: St = { frame: { kind: VK.Lin, start: 0.0, length: 1.0 }, n: 0 };
console.log(`${none.divergences()}|${rnd.divergences()}|${lin.divergences()}|${rnd.twice()}`);
