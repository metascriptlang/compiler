// @stdout: abc|abc|abc|abc

function f(): string {
	let s = "abc";
	let out = "";
	for (const ch of s) { out += String.fromCharCode(ch as int32); s = "xyz"; }
	return out;
}
function g(): string {
	let s = "abc";
	let out = "";
	for (const ch of s) { out += String.fromCharCode(ch as int32); s += "d"; }
	return out;
}
function h(): string {
	let s = "abc";
	let out = "";
	for (const ch of s) { out += String.fromCharCode(ch as int32); s = ""; }
	return out;
}
let gs = "abc";
function k(): string {
	let out = "";
	for (const ch of gs) { out += String.fromCharCode(ch as int32); gs = "q"; }
	return out;
}
function run(fn: () => string): string { try { return fn(); } catch (e) { return "threw:" + e.message; } }
console.log(run(f) + "|" + run(g) + "|" + run(h) + "|" + run(k));
