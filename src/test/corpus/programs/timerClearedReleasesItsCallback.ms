// @stdout: timeout cleared 1
// @stdout: interval cleared 2
// @stdout: actor cleared 3
// @stdout: worker cleared 4
// @exit: 0
// note: a timer cleared before it fires, armed by a function, an interval, an actor and a pool task, releases its callback's captures by the time the program ends, which is before the timer's delay (old runtime: the program exited only when each delay had passed)

class Box { v: int32; constructor(v: int32) { this.v = v; } }

function arm(b: Box): int32 {
	const id = setTimeout(() => { console.log(`fired ${b.v}`); }, 3000);
	clearTimeout(id);
	return b.v;
}

actor Clock {
	armAndClear(): int32 {
		return arm(new Box(3));
	}
}

console.log(`timeout cleared ${arm(new Box(1))}`);
const box = new Box(2);
const iv = setInterval(() => { console.log(`tick ${box.v}`); }, 3000);
clearInterval(iv);
console.log(`interval cleared ${box.v}`);
const c = new Clock();
console.log(`actor cleared ${await c.armAndClear()}`);
console.log(`worker cleared ${await spawn((): int32 => arm(new Box(4)))}`);
