// @stdout: 5 3
// @skip-js: `extern` binds a C symbol; the JS backend has no C linkage
// @skip-raiser: the Raiser VM cannot call a C extern
@include("string.h")
class Str {
	static extern len(a: cstring): int64 from "strlen";
}
const a: cstring = "hello";
const b: cstring = "abc";
console.log(Str.len(a), Str.len(b));
