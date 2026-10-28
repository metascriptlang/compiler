// @stdout: a b|a%20b|é|%C3%A9|😀|%F0%9F%98%80|%7E-_.!~*'()|a/b?c=d&e|URIError|URIError|URIError|URIError|URIError
// @exit: 0
// @skip-raiser: raiser strings are text, not bytes
function failure(s: string): string {
	try {
		decodeURIComponent(s);
		return "none";
	} catch (e) {
		return e instanceof URIError ? "URIError" : "other";
	}
}
const parts: string[] = [
	decodeURIComponent("a%20b"),
	encodeURIComponent("a b"),
	decodeURIComponent("%C3%A9"),
	encodeURIComponent("é"),
	decodeURIComponent("%F0%9F%98%80"),
	encodeURIComponent("😀"),
	encodeURIComponent("~-_.!~*'()").replace("~", "%7E"),
	decodeURIComponent(encodeURIComponent("a/b?c=d&e")),
	failure("%"),
	failure("%zz"),
	failure("%C3"),
	failure("%C3%28"),
	failure("%ED%A0%80"),
];
console.log(parts.join("|"));
