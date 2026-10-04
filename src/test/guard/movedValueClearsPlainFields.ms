class Anchor { value: int32 = 13; }
type Id = distinct int32;
enum WideFlag {
	F00, F01, F02, F03, F04, F05, F06, F07,
	F08, F09, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23,
	F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39,
	F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55,
	F56, F57, F58, F59, F60, F61, F62, F63,
	High,
}
struct Plain { id: int32; code: Id; flag: boolean; slots: int32[2]; ptr: Ptr<void>; bits: BitSet<WideFlag>; }
struct Resource { plain: Plain; name: string; }

let observations: string = "";
function onDestroy(this x: Resource): void {
	observations += x.plain.id.toString() + ":" + (x.plain.code as int32).toString() + ":" + (x.plain.flag ? "1" : "0") + ":" + x.plain.slots[0].toString() + ":" + x.plain.slots[1].toString() + ":" + (x.plain.ptr == null ? "0" : "1") + ":" + (x.plain.bits.isEmpty() ? "0" : "1") + "|";
}

function nested(): void {
	const anchor = new Anchor();
	let source: Resource = { plain: { id: 7, code: 9 as Id, flag: true, slots: [3, 4], ptr: anchor as Ptr<void>, bits: (0 as BitSet<WideFlag>).incl(WideFlag.High) }, name: "r" };
	const taken = move source;
	if (taken.plain.id != 7 || (taken.plain.code as int32) != 9 || !taken.plain.flag
		|| taken.plain.slots[0] != 3 || taken.plain.slots[1] != 4 || taken.plain.ptr == null
		|| !taken.plain.bits.has(WideFlag.High)) {
		console.log("GUARD-FAIL moved destination");
		process.exit(1);
	}
}

nested();
if (observations != "7:9:1:3:4:1:1|0:0:0:0:0:0:0|") {
	console.log("GUARD-FAIL moved fields " + observations);
	process.exit(1);
}
console.log("GUARD-OK");
