// @stdout: ann 1 t | bob 1 t | 1 b | 0 s | 5 s | 7 1 | 3 two
interface User { id: int32; name: string; tag?: string }
type Opt = { a?: number | null; s: string };

function update<T>(base: T, patch: Partial<T>): T { return { ...base, ...patch }; }

let calls = 0;
function seven(): number { calls += 1; return 7; }

function main(): void {
	const base: User = { id: 1, name: "ann", tag: "t" };
	const empty: Partial<User> = {};
	const merged = { ...base, ...empty };
	const named: Partial<User> = { name: "bob" };
	const typed: User = { ...base, ...named };
	const viaGeneric = update(base, { name: "b" });
	const absent: Opt = { s: "s" };
	const given: Opt = { a: 5, s: "s" };
	const kept = { a: 0, ...absent };
	const over = { a: 0, ...given };
	const once = { a: seven(), ...absent };
	const later: Partial<User> = { id: 3 };
	const both = { ...base, name: "two", ...later };
	console.log(merged.name + " " + merged.id + " " + merged.tag
		+ " | " + typed.name + " " + typed.id + " " + typed.tag
		+ " | " + viaGeneric.id + " " + viaGeneric.name
		+ " | " + kept.a + " " + kept.s
		+ " | " + over.a + " " + over.s
		+ " | " + once.a + " " + calls
		+ " | " + both.id + " " + both.name);
}
main();
