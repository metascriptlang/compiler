// @stdout: for boom 2|while boom 1|kept 3
// note: a catch binding is defined afresh each time its handler runs, so its last read inside a loop is a move (C refused `move e` there as "still used after this point", reading the next iteration's handler as a later use of the same binding); for and while loops, the moved exception kept past the loop.

function boom(i: int32): int32 { throw new Error(`boom ${i}`); }

function inFor(): string {
	let last = "none";
	for (let i = 0; i < 3; i += 1) {
		try { boom(i); } catch (e) { const kept = move e; last = kept.message; }
	}
	return last;
}
function inWhile(): string {
	let last = "none";
	let i = 0;
	while (i < 2) {
		try { boom(i); } catch (e) { last = (move e).message; }
		i += 1;
	}
	return last;
}
function keepAll(): int32 {
	const kept: Error[] = [];
	for (let i = 0; i < 3; i += 1) {
		try { boom(i); } catch (e) { kept.push(move e); }
	}
	return kept.length;
}

console.log(`for ${inFor()}|while ${inWhile()}|kept ${keepAll()}`);
