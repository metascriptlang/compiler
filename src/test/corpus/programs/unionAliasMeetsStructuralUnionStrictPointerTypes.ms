// @stdout: 1 1 1 1 7 7

@passC("-Werror=incompatible-pointer-types");

interface Cell { v: int32 }
interface Other { w: int32 }
type Named = Cell | Other;

function readV(u: Cell | Other): int32 { return (u as Cell).v; }
function readN(u: Named): int32 { return (u as Cell).v; }
function otherV(u: Cell | Other): int32 { return (u as Other).w; }
function otherN(u: Named): int32 { return (u as Other).w; }

function main(): void {
	const c: Cell = { v: 1 };
	const o: Other = { w: 7 };
	const namedCell: Named = c;
	const plainCell: Cell | Other = c;
	const namedOther: Named = o;
	const plainOther: Cell | Other = o;
	console.log(readV(namedCell), readN(namedCell), readV(plainCell), readN(plainCell), otherV(namedOther), otherN(plainOther));
}
main();
