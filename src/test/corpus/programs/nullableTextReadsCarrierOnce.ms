// @stdout: chain=web-1
// @stdout: nested=web-2
// @stdout: string=web-3
// @stdout: concat=web-4
// @stdout: template=web-5
// @stdout: args=web-6 6
// @stdout: call=l-7
// @stdout: absent=null
// @stdout: class=web-8
// @stdout: ternary=l-1 calls=2
// note: printing or stringifying a value that may be null, when it is not a plain name or field (an optional chain, a ternary), evaluates it once: the presence test and the payload read the same value.

struct Host {
	name: string;
	cores: int32;
}

struct Rack {
	host: Host | null;
}

class Box {
	name: string;

	constructor(name: string) {
		this.name = name;
	}
}

let calls = 0;

function find(n: int32): Host | null {
	if (n > 0) return { name: `web-${n}`, cores: n };
	return null;
}

function rack(n: int32): Rack | null {
	return { host: find(n) };
}

function box(n: int32): Box | null {
	return n > 0 ? new Box(`web-${n}`) : null;
}

function label(n: int32): string | null {
	calls += 1;
	return n > 0 ? `l-${n}` : null;
}

function show(n: int32): void {
	const big = find(n);
	console.log("chain=" + big?.name);
	console.log(big?.name);
	const a = rack(n + 1);
	console.log("nested=" + a?.host?.name);
	console.log(a?.host?.name);
	const big3 = find(n + 2);
	console.log("string=" + String(big3?.name));
	const big4 = find(n + 3);
	console.log("concat=" + big4?.name);
	const big5 = find(n + 4);
	console.log(`template=${big5?.name}`);
	const big6 = find(n + 5);
	console.log("args=" + big6?.name, big6?.cores);
	const s = label(n + 6);
	console.log("call=" + s?.toString());
	console.log(s?.toString());
	const none = find(0);
	console.log("absent=" + none?.name);
	console.log(none?.name);
	const b = box(n + 7);
	console.log("class=" + b?.name);
	console.log(b?.name);
	console.log("ternary=" + (n > 0 ? label(n) : null), `calls=${calls}`);
}

show(1);
