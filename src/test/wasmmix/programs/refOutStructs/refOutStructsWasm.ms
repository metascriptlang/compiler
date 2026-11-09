export enum Tone { Warm = 2, Cool = 5 }
export struct Mark { at: int32; note: string | null; }
export struct Card { id: int32; title: string; tone: Tone; score: float64 | null; mark: Mark; }

@wasm
export function retitle(ref c: Card, suffix: string): int32 {
	c.id = c.id + 1;
	c.title = c.title + suffix;
	c.tone = c.tone == Tone.Warm ? Tone.Cool : Tone.Warm;
	const s = c.score;
	c.score = s == null ? 0.5 : null;
	c.mark.at = c.mark.at * 2;
	c.mark.note = c.mark.note == null ? "noted" : null;
	return c.title.length;
}

@wasm
export function deal(out c: Card, id: int32): void {
	c = { id, title: `card ${id}`, tone: Tone.Cool, score: null, mark: { at: id, note: "fresh" } };
}

@wasm
export function dealThenThrow(out c: Card, fail: boolean): void {
	c = { id: 99, title: "dealt", tone: Tone.Warm, score: 9.5, mark: { at: 1, note: null } };
	if (fail) throw new Error("dealt, then threw");
}

@wasm
export function swapMaybe(ref c: Card | null, id: int32): void {
	if (c == null) {
		c = { id, title: "made", tone: Tone.Warm, score: 1.25, mark: { at: 0, note: null } };
	} else {
		c = null;
	}
}

@wasm
export function nudge(ref m: Mark): void {
	m.at = m.at + 1;
	const note = m.note;
	m.note = note == null ? "nudged" : note + "+";
}
