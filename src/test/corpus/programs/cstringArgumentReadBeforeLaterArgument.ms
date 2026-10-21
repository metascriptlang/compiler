// @stdout: module=22 field=22 element=22 popped=22 nested=22
// @skip-js: binds libc strcspn through string.h
// @skip-raiser: binds libc strcspn through string.h, which has no Raiser host bridge

@include("string.h")
extern function strcspn(a: cstring, b: cstring): int64;

class Holder { name: string; constructor(name: string) { this.name = name; } }

function fresh(): string { return `value-${1}-heap-heap-heap`; }
function other(): string { return `other-${2}-padpadpadpadpad`; }

let banner: string = fresh();
function rewriteBanner(): string { banner = other(); return "x"; }

function rename(h: Holder): string { h.name = other(); return "x"; }
function replaceFirst(a: string[]): string { a[0] = other(); return "x"; }
function dropLast(a: string[]): string { a.pop(); return "x"; }

function viaField(): int64 {
	const h = new Holder(fresh());
	return strcspn(h.name, rename(h));
}

function viaElement(): int64 {
	const a: string[] = [fresh()];
	return strcspn(a[0], replaceFirst(a));
}

function viaPop(): int64 {
	const a: string[] = [fresh()];
	return strcspn(a[0], dropLast(a));
}

function viaNested(): int64 {
	const h = new Holder(fresh());
	return strcspn(h.name, `${rename(h)}`);
}

console.log(`module=${strcspn(banner, rewriteBanner())} field=${viaField()} element=${viaElement()} popped=${viaPop()} nested=${viaNested()}`);
