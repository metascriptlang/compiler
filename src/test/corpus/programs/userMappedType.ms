// @stdout: true z | 4 | x | 9 g | 2 3 | 6
interface User { id: int32; name: string; email?: string }
type Nullable<T> = { [K in keyof T]: T[K] | null };
type Mutable<T> = { -readonly [K in keyof T]: T[K] };
type Frozen<T> = { readonly [K in keyof T]: T[K] };
type NoEmail<T> = { [K in keyof T as Exclude<K, "email">]: T[K] };
type Boxes<T> = { [K in keyof T]: T[K][] };
type Flags<K extends string> = { [P in K]: int32 };

function main(): void {
	const n: Nullable<User> = { id: null, name: "z", email: null };
	const f: Frozen<User> = { id: 4, name: "f" };
	const m: Mutable<Frozen<User>> = { id: 0, name: "m" };
	m.id = f.id;
	const x: Partial<User> = { email: "x" };
	const g: NoEmail<User> = { id: 9, name: "g" };
	const b: Boxes<{ a: int32; c: int32 }> = { a: [1, 1], c: [1, 2, 3] };
	const fl: Flags<"p" | "q"> = { p: 2, q: 4 };
	console.log((n.id == null) + " " + n.name + " | " + m.id + " | " + (x.email ?? "none") + " | " + g.id + " " + g.name
		+ " | " + b.a.length + " " + b.c.length + " | " + (fl.p + fl.q));
}
main();
