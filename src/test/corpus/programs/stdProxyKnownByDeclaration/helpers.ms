function proxyTarget(x: number): number { return x; }
class Reflect { static get(a: number, b: number): number { return 5; } }
class Handler {}
function Handler_get(t: { a: number }, k: string): number { return 99; }

export function shadowedHelpers(): string {
	const p = newProxy({ a: 4 }, new Handler());
	const q = newProxy([5, 6], {});
	q.push(7);
	return `${p.a} ${q[0]} ${q.length} ${proxyTarget(3)} ${Reflect.get(0, 0)} ${Handler_get({ a: 0 }, "a")}`;
}
