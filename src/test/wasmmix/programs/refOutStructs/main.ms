// @stdout: 8 2/first é!/Cool/0.5/6:noted | 1/first é/Warm/~/3:~
// @stdout: 3/first é!?/Warm/~/12:~
// @stdout: 4/card 4/Cool/~/4:fresh
// @stdout: caught dealt, then threw: 99/dealt/Warm/9.5/1:~
// @stdout: 5/made/Warm/1.25/0:~
// @stdout: ~
// @stdout: 3/first é!?/Warm/~/14:nudged+
// @stdout: 10:~ 21:x+
import { Tone, Mark, Card, retitle, deal, dealThenThrow, swapMaybe, nudge } from "./refOutStructsWasm";

function showText(v: string | null): string {
	if (v == null) { return "~"; }
	return v;
}

function showNum(v: float64 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function show(c: Card): string {
	return `${c.id}/${c.title}/${c.tone}/${showNum(c.score)}/${c.mark.at}:${showText(c.mark.note)}`;
}

function showMaybe(c: Card | null): string {
	if (c == null) { return "~"; }
	return show(c);
}

let card: Card = { id: 1, title: "first é", tone: Tone.Warm, score: null, mark: { at: 3, note: null } };
const before = card;
const n = retitle(card, "!");
console.log(`${n} ${show(card)} | ${show(before)}`);
retitle(card, "?");
console.log(show(card));

function fresh(): void {
	let c: Card;
	deal(out c, 4);
	console.log(show(c));
}
fresh();

let kept: Card = { id: 7, title: "kept", tone: Tone.Cool, score: 2, mark: { at: 2, note: "k" } };
try {
	dealThenThrow(kept, true);
} catch (e) {
	console.log(`caught ${e.message}: ${show(kept)}`);
}

let maybe: Card | null = null;
swapMaybe(maybe, 5);
console.log(showMaybe(maybe));
swapMaybe(maybe, 6);
console.log(showMaybe(maybe));

nudge(card.mark);
nudge(card.mark);
console.log(show(card));
let marks: Vec<Mark> = [{ at: 10, note: null }, { at: 20, note: "x" }];
nudge(marks[1]);
console.log(`${marks[0].at}:${showText(marks[0].note)} ${marks[1].at}:${showText(marks[1].note)}`);
