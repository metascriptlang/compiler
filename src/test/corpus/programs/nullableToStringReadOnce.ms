// Parity program: `.toString()` called directly on a nullable number reads its operand once, for a held value and for null.
//
// @stdout: maybe:2
// @stdout: 5,null
// @exit: 0

let reads = 0;
function nextMaybe(): int32 | null { reads += 1; return 5; }
function nextNone(): int32 | null { reads += 1; return null; }

function main(): void {
	const m = nextMaybe().toString();
	const none = nextNone().toString();
	console.log(`maybe:${reads}`);
	console.log(`${m},${none}`);
}
main();
