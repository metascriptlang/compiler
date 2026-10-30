// @xfail(raiser): the Raiser VM cannot call a C extern (getenv, setenv)
// @skip-js: getenv and setenv are extern C functions; JS has none
// @stdout: unset
// @stdout: set xc-value
// @stdout: fallback
// @stdout: xc-value
// @stdout: field unset
// @stdout: field xc-value
// @stdout: param none
// @stdout: param xc-value
// A C char* may be NULL, so an extern returning `cstring | null` is the bare pointer with NULL
// for null, read with `== null` and `??`, held in a struct field and taken as a parameter.
@include("stdlib.h")
extern function getenv(name: cstring): cstring | null;
extern function setenv(name: cstring, value: cstring, overwrite: int32): int32;

struct Holder {
	value: cstring | null;
}

function describe(v: cstring | null): string {
	if (v == null) return "param none";
	const s: string = v;
	return "param " + s;
}

function lookup(name: cstring): string {
	const v = getenv(name);
	if (v == null) return "unset";
	const s: string = v;
	return "set " + s;
}

setenv("XC_PRESENT", "xc-value", 1);

console.log(lookup("XC_ABSENT"));
console.log(lookup("XC_PRESENT"));

const fallback: string = getenv("XC_ABSENT") ?? "fallback";
const present: string = getenv("XC_PRESENT") ?? "fallback";
console.log(fallback);
console.log(present);

const absentHolder: Holder = { value: getenv("XC_ABSENT") };
const presentHolder: Holder = { value: getenv("XC_PRESENT") };
console.log(absentHolder.value == null ? "field unset" : "field set");
const heldValue = presentHolder.value;
if (heldValue != null) {
	const s: string = heldValue;
	console.log("field " + s);
}

console.log(describe(getenv("XC_ABSENT")));
console.log(describe(getenv("XC_PRESENT")));
