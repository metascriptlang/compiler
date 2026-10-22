// @stdout: 4 4 true false
// note: a generic BitSet<T> instantiated with a 20-member enum is four bytes wide
// in both a class field and a function parameter.

class Box<T> {
	s: BitSet<T>;
	constructor(s: BitSet<T>) { this.s = s; }
	width(): int32 { return sizeof(BitSet<T>); }
}

function widthOf<T>(s: BitSet<T>): int32 { return sizeof(BitSet<T>); }

enum E { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13, M14, M15, M16, M17, M18, M19 }

function main(): void {
	const b = new Box<E>(E.M19 | E.M2);
	console.log(`${b.width()} ${widthOf<E>(b.s)} ${b.s.has(E.M19)} ${b.s.has(E.M5)}`);
}

main();
