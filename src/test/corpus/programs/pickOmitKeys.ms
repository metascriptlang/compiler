// @stdout: 2 true | 3 n | 5 five | a c
interface User { id: int32; name: string; email?: string; admin: boolean }
type Contact = Pick<User, "id" | "email">;
type Plain = Omit<User, "email" | "admin">;
type Letters = Exclude<"a" | "b" | "c", "b">;
type Kept = Extract<"a" | "b" | "c", "a" | "c">;

function idOf(c: Contact): int32 { return c.id; }

function main(): void {
	const p: Contact = { id: 2 };
	const o: Plain = { id: 3, name: "n" };
	const one: Pick<Plain, "name"> & { n: int32 } = { name: "five", n: 5 };
	const l: Letters = "a";
	const k: Kept = "c";
	console.log(idOf(p) + " " + (p.email == null) + " | " + o.id + " " + o.name + " | " + one.n + " " + one.name + " | " + l + " " + k);
}
main();
