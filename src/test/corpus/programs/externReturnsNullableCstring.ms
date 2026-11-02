// @xfail(raiser): the Raiser VM cannot call a C extern (strstr)
// @skip-js: strstr is an extern C function; JS has none
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
@include("string.h")
extern function strstr(haystack: cstring, needle: cstring): cstring | null;

struct Holder {
	value: cstring | null;
}

function describe(v: cstring | null): string {
	if (v == null) return "param none";
	const s: string = v as string;
	return "param " + s;
}

function lookup(name: cstring): string {
	const v = strstr("xc-value", name);
	if (v == null) return "unset";
	const s: string = v as string;
	return "set " + s;
}

console.log(lookup("XC_ABSENT"));
console.log(lookup("xc"));

const absentRaw = strstr("xc-value", "XC_ABSENT");
const presentRaw = strstr("xc-value", "xc");
const fallback: string = absentRaw == null ? "fallback" : absentRaw as string;
const present: string = presentRaw == null ? "fallback" : presentRaw as string;
console.log(fallback);
console.log(present);

const absentHolder: Holder = { value: strstr("xc-value", "XC_ABSENT") };
const presentHolder: Holder = { value: strstr("xc-value", "xc") };
console.log(absentHolder.value == null ? "field unset" : "field set");
const heldValue = presentHolder.value;
if (heldValue != null) {
	const s: string = heldValue as string;
	console.log("field " + s);
}

console.log(describe(strstr("xc-value", "XC_ABSENT")));
console.log(describe(strstr("xc-value", "xc")));
