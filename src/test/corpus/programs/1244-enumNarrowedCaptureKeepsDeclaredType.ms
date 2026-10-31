// @stdout: 1 2 2 3 2
enum Kind { Init, Connected, Disconnected }
function attempt(n: int32, kind: Kind | null): int32 { return kind === null ? n : n + 1; }
function run(f: () => int32): int32 { return f(); }
function call(kind: Kind | null, n: int32): int32 {
	if (kind == Kind.Init && n == 99) return 1;
	if (kind !== null && kind != Kind.Init && n == 98) return 2;
	return run((): int32 => attempt(n, kind));
}
function callIn(kind: Kind | null, n: int32): int32 {
	if (kind !== null && kind != Kind.Init && n == 98) return 2;
	return run((): int32 => attempt(n, kind));
}
function callOnly(kind: Kind | null, n: int32): int32 {
	if (kind == Kind.Init && n == 99) return 1;
	return run((): int32 => attempt(n, kind));
}
function callLet(pick: Kind | null, n: int32): int32 {
	let k: Kind | null = pick;
	if (k !== null && k != Kind.Init && n == 98) return 2;
	return run((): int32 => attempt(n, k));
}
console.log(call(null, 1), call(Kind.Init, 1), callIn(Kind.Connected, 1), callOnly(null, 3), callLet(Kind.Disconnected, 1));
