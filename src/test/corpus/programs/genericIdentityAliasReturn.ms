// @stdout: 8 #334 #999
// note: a generic routine whose return type is an identity alias (`type Theme<T> = T`) returns the
//   argument's own type and representation, so a returned object literal is read like the literal
//   itself; C once read it with `.` on a pointer (inbox 2026-09-30-generic-alias-return-object-emits-dot-on-pointer,
//   compiler half fixed before 59c3c6c4, not bisected). Module-level and in-function bindings both read it.

type Theme<T> = T;

function themeOf<T>(o: T): Theme<T> {
	return o;
}

const theme = themeOf({ sp2: 8, brand: "#334" });

function local(): string {
	const t = themeOf({ sp2: 1, brand: "#999" });
	return t.brand;
}

console.log(`${theme.sp2} ${theme.brand} ${local()}`);
