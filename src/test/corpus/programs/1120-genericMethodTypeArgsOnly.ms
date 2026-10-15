// Parity program — a generic method whose type parameters appear nowhere
// in its signature is still instantiated per explicit type argument, as an
// instance method, a static method and a method of a generic class.
//
// @stdout: 4|1|x|s|g|8:1
// @exit: 0

class Tool {
	size<T>(): int32 { const s = @comptime { return sizeof(T); }; return s; }
	name<T>(): string { return "x"; }
	static tag<T>(): string { return "s"; }
	pair<A, B>(): string {
		const a = @comptime { return sizeof(A); };
		const b = @comptime { return sizeof(B); };
		return `${a}:${b}`;
	}
}

class Box<U> {
	name<T>(): string { return "g"; }
}

const t = new Tool();
const box = new Box<int32>();
console.log([
	`${t.size<int32>()}`,
	`${t.size<boolean>()}`,
	t.name<int32>(),
	Tool.tag<int32>(),
	box.name<string>(),
	t.pair<int64, boolean>(),
].join("|"));
