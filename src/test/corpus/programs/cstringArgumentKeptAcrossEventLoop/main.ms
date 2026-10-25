// @stdout: field=28 element=28 module=28 after=short:short:short
// @skip-js: binds the C fixture pump.c, which runs the event loop inside the call
// @skip-raiser: binds the C fixture pump.c, whose msTestLengthAfterPump has no Raiser host bridge

@include("./pump.h")
@compile("./pump.c")
extern function msTestLengthAfterPump(s: cstring): int64;

class Holder { name: string; constructor(name: string) { this.name = name; } }

function fresh(): string { return `cfg:${"x".repeat(24)}`; }

const holder = new Holder(fresh());
const names: string[] = [fresh()];
let banner = fresh();

function main(): void {
	setTimeout((): void => { holder.name = "short"; }, 0);
	const field = msTestLengthAfterPump(holder.name);
	setTimeout((): void => { names[0] = "short"; }, 0);
	const element = msTestLengthAfterPump(names[0]);
	setTimeout((): void => { banner = "short"; }, 0);
	const module = msTestLengthAfterPump(banner);
	console.log(`field=${field} element=${element} module=${module} after=${holder.name}:${names[0]}:${banner}`);
}

main();
