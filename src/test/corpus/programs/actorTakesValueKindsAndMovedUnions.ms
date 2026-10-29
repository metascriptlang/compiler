// @stdout: key 7 {Shift, Alt}|mask 2|wide true 3|cells 321|meters 5|msg key 9|msg click 4,5
import { stop, ExitReason } from "std/actor";

enum Mod { Shift, Ctrl, Alt }
enum Wide { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39, W40, W41, W42, W43, W44, W45, W46, W47, W48, W49, W50, W51, W52, W53, W54, W55, W56, W57, W58, W59, W60, W61, W62, W63, W64, W65, W66, W67, W68, W69 }
enum Ask { Key, Click }
type Meters = distinct float64;
struct Held { mods: BitSet<Mod>; }
struct Key { code: int32; held: Held; }
struct Hit { x: int32; y: int32; }
type Msg = match (kind: Ask) {
	Ask.Key => { code: int32 },
	Ask.Click => { hit: Hit },
};

actor Shell {
	private log: string[] = [];
	key(k: Key): void { this.log.push(`key ${k.code} ${k.held.mods.toString()}`); }
	mask(m: BitSet<Mod>): int32 { return m.size(); }
	wide(w: BitSet<Wide>): string { return `${w.has(Wide.W69) && !w.has(Wide.W1)} ${w.size()}`; }
	cells(c: int32[3]): int32 { return c[0] + c[1] * 10 + c[2] * 100; }
	meters(m: Meters): float64 { return (m as float64) * 2; }
	msg(m: Msg): void {
		if (m.kind === Ask.Key) { this.log.push(`msg key ${m.code}`); return; }
		if (m.kind === Ask.Click) { this.log.push(`msg click ${m.hit.x},${m.hit.y}`); }
	}
	lines(): string {
		let all = this.log.join("|");
		return move all;
	}
}

const shell = new Shell();
const held: Held = { mods: Mod.Shift | Mod.Alt };
shell.key({ code: 7, held: held });
const masked = await shell.mask(Mod.Shift | Mod.Ctrl);
const wideSet = (0 as BitSet<Wide>).incl(Wide.W0).incl(Wide.W40).incl(Wide.W69);
const wide = await shell.wide(wideSet);
const fixed: int32[3] = [1, 2, 3];
const cells = await shell.cells(fixed);
const meters = await shell.meters(2.5 as Meters);
function sendMessages(to: Shell): void {
	let key: Msg = { kind: Ask.Key, code: 9 };
	to.msg(move key);
	let click: Msg = { kind: Ask.Click, hit: { x: 4, y: 5 } };
	to.msg(move click);
}
sendMessages(shell);
const sent = await shell.lines();
console.log(`${sent.split("|")[0]}|mask ${masked}|wide ${wide}|cells ${cells}|meters ${meters}|${sent.split("|").slice(1).join("|")}`);
stop(shell.pid, ExitReason.Normal);
