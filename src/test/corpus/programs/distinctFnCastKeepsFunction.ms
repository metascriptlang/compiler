// @stdout: button|button|button|button|link|button|none|link|link
type Role = "button" | "link";
type Acc<T> = distinct (() => T);
function valueOf<T>(this a: Acc<T>): T { return a(); }

type RoleFn = distinct (() => Role);
function valueOf(this a: RoleFn): Role { return a(); }

function viaParam(m: Acc<Role> | null): string {
	if (m === null) return "none";
	return (m as () => string)();
}

function viaBinding(m: Acc<Role> | null): string {
	if (m === null) return "none";
	const read = m as () => string;
	return read();
}

const f = ((): Role => "button") as Acc<Role>;
const g = ((): Role => "link") as RoleFn;
const asPayload: Role = f as Role;
const monoPayload: Role = g as Role;
const parts: string[] = [
	(f as () => string)(),
	(f as () => Role)(),
	asPayload,
	viaBinding(f),
	viaParam(((): Role => "link") as Acc<Role>),
	viaParam(f),
	viaParam(null),
	(g as () => string)(),
	monoPayload,
];
console.log(parts.join("|"));
