// @stdout: true false true
// @stdout: false true
enum Kind { Inherit, Home, Path }
struct Dir = match (kind: Kind) {
	Kind.Inherit => {},
	Kind.Home => {},
	Kind.Path => { path: string },
};

function pick(d: Dir | null, cli: boolean): Dir {
	return d ?? (cli ? { kind: Kind.Inherit } : { kind: Kind.Home });
}

console.log(`${pick(null, true).kind == Kind.Inherit} ${pick(null, true).kind == Kind.Home} ${pick({ kind: Kind.Path, path: "p" }, true).kind == Kind.Path}`);
console.log(`${pick(null, false).kind == Kind.Inherit} ${pick(null, false).kind == Kind.Home}`);
