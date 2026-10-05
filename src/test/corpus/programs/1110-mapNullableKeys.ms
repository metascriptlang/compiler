// @xfail(raiser): raiser runtime error: Unknown host function: msHiXorLo
// Parity program — a nullable key (`T | null`) keeps null apart from every value of T, the zero
// value included: on C the key hashes like an Option, folding the payload and its presence.
//
// @stdout: int=7,9,2 int-del=false,true,1 str=1,2,2 str-del=true,false,1 struct=3,4 enum=5,6 bool=8,9 tuple=10,11,2
// @exit: 0

enum Color { Red, Green }

struct Pos { x: int32; y: int32; }

function main(): void {
	const byInt = new Map<int32 | null, int32>();
	byInt.set(0, 7);
	byInt.set(null, 9);
	const intRead = `${byInt.get(0) ?? -1},${byInt.get(null) ?? -1},${byInt.size}`;
	byInt.delete(null);
	const intDel = `${byInt.has(null)},${byInt.has(0)},${byInt.size}`;

	const byStr = new Map<string | null, int32>();
	byStr.set("", 1);
	byStr.set(null, 2);
	const strRead = `${byStr.get("") ?? -1},${byStr.get(null) ?? -1},${byStr.size}`;
	byStr.delete("");
	const strDel = `${byStr.has(null)},${byStr.has("")},${byStr.size}`;

	const byPos = new Map<Pos | null, int32>();
	byPos.set({ x: 0, y: 0 }, 3);
	byPos.set(null, 4);
	const origin: Pos = { x: 0, y: 0 };

	const byColor = new Map<Color | null, int32>();
	byColor.set(Color.Red, 5);
	byColor.set(null, 6);

	const byFlag = new Map<boolean | null, int32>();
	byFlag.set(false, 8);
	byFlag.set(null, 9);

	const byPair = new Map<[int32, int32 | null], int32>();
	byPair.set([1, 0], 10);
	byPair.set([1, null], 11);

	console.log(`int=${intRead} int-del=${intDel} str=${strRead} str-del=${strDel} struct=${byPos.get(origin) ?? -1},${byPos.get(null) ?? -1} enum=${byColor.get(Color.Red) ?? -1},${byColor.get(null) ?? -1} bool=${byFlag.get(false) ?? -1},${byFlag.get(null) ?? -1} tuple=${byPair.get([1, 0]) ?? -1},${byPair.get([1, null]) ?? -1},${byPair.size}`);
}

main();
