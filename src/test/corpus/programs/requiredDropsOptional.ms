// @stdout: 1 | 2 | 4 y | e
interface User { id: int32; name: string; email?: string }
type Strict<T> = { [K in keyof T]-?: T[K] };

function emailLength(u: Required<User>): int32 { return u.email.length; }
function firstLetter<T>(r: Required<T>, pick: (t: Required<T>) => string): string { return pick(r).substring(0, 1); }

function main(): void {
	const r: Required<User> = { id: 1, name: "a", email: "e" };
	const s: Strict<User> = { id: 2, name: "s", email: "ab" };
	const loose: Partial<Required<User>> = { id: 4 };
	const letter = firstLetter<User>(r, (u: Required<User>): string => u.email);
	console.log(emailLength(r) + " | " + s.email.length + " | " + loose.id + " " + (loose.name ?? "y") + " | " + letter);
}
main();
