// @stdout: has=2 len=8 tmpl=3 early=yes do=3

function has(s: string): boolean { return s.length > 0; }

function untilFound(dir: string): int32 {
	let n: int32 = 0;
	while (has(dir + "done")) {
		n += 1;
		if (n >= 2) return n;
	}
	return n;
}

function byLength(dir: string): int32 {
	let n: int32 = 0;
	while ((dir + "x").length > n) n += 1;
	return n;
}

function byTemplate(name: string): int32 {
	let n: int32 = 0;
	while (`${name}-${n}` != `${name}-3`) n += 1;
	return n;
}

function early(dir: string): string {
	while (has(dir + "a")) {
		if (has(dir + "b")) return "yes";
	}
	return "no";
}

function doLoop(name: string): int32 {
	let n: int32 = 0;
	do { n += 1; } while (n < 3 && (name + n).length > 0);
	return n;
}

const base = "/tmp/" + "c";
console.log(`has=${untilFound(base)} len=${byLength(base + "/")} tmpl=${byTemplate(base)} early=${early(base)} do=${doLoop("ab")}`);
