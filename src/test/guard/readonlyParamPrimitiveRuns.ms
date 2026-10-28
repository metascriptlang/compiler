// A type parameter read through Readonly<T> binds to a primitive argument
//
// INVARIANT: Readonly<T> maps a primitive to itself, so a boolean, string or number argument
//   binds T to that primitive, bare or inside a nullable, as it binds T to a struct's own type.
//
// RED MEANS: a primitive argument stopped binding T through Readonly<T>, or through the nullable form.
//
// GUARD-JS

function flag<T>(x: Readonly<T>): T { return x as T; }
function label<T>(x: Readonly<T | null>): int32 { return x == null ? -1 : 2; }
function same<T>(a: Readonly<T>, b: Readonly<T>): boolean { return a == b; }

function main(): void {
	const n: number = 1.5;
	if (flag(true) !== true || flag("s") !== "s" || flag(n) !== 1.5) throw new Error("bare");
	if (label("s") != 2 || label(n) != 2 || label(true) != 2) throw new Error("nullable");
	if (!same(1, 1) || same("a", "b")) throw new Error("pair");
	console.log("GUARD-OK");
}

main();
