// @stdout: 3 | 1 2 | 5 | 2 | 9
type Axis = "x" | "y";
type Counts = Record<string, int32>;

function total(r: Record<Axis, int32>): int32 { return r.x + r.y; }

function main(): void {
	const point: Record<Axis, int32> = { x: 1, y: 2 };
	const counts: Counts = new Map<string, int32>();
	counts.set("k", 5);
	counts.set("j", 4);
	const flags: Record<"on", Record<"level", int32>> = { on: { level: 9 } };
	console.log(total(point) + " | " + point.x + " " + point.y + " | " + (counts.get("k") ?? 0) + " | " + counts.size + " | " + flags.on.level);
}
main();
