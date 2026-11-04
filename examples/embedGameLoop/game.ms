extern function spawned(id: int32, x: number, y: number): void from "game.spawned";
extern function sqrtInPlace(x: number): number from "game.sqrtInPlace";
extern function sqrtBoxed(x: number): number from "game.sqrtBoxed";

interface Ball {
	x: number;
	y: number;
	vx: number;
	vy: number;
}

const WIDTH = 800.0;
const HEIGHT = 600.0;
const balls: Ball[] = [];
let frames: int32 = 0;

export function start(count: int32): int32 {
	for (let i: int32 = 0; i < count; i += 1) {
		const x = (i * 37 % 800) as number;
		const y = (i * 91 % 600) as number;
		balls.push({ x, y, vx: 40.0 + ((i % 7) as number) * 10.0, vy: 30.0 + ((i % 5) as number) * 12.0 });
		spawned(i, x, y);
	}
	return balls.length;
}

export function update(dt: number): int32 {
	for (let i = 0; i < balls.length; i += 1) {
		balls[i].x += balls[i].vx * dt;
		balls[i].y += balls[i].vy * dt;
		if (balls[i].x < 0.0 || balls[i].x > WIDTH) balls[i].vx = -balls[i].vx;
		if (balls[i].y < 0.0 || balls[i].y > HEIGHT) balls[i].vy = -balls[i].vy;
	}
	frames += 1;
	return frames;
}

export function ballX(i: int32): number {
	return balls[i].x;
}

export function noop(): void {
}

export function stdSqrtLoop(n: int32): number {
	let acc = 1.0;
	for (let i: int32 = 0; i < n; i += 1) acc = Math.sqrt(acc + 2.0);
	return acc;
}

export function inPlaceSqrtLoop(n: int32): number {
	let acc = 1.0;
	for (let i: int32 = 0; i < n; i += 1) acc = sqrtInPlace(acc + 2.0);
	return acc;
}

export function boxedSqrtLoop(n: int32): number {
	let acc = 1.0;
	for (let i: int32 = 0; i < n; i += 1) acc = sqrtBoxed(acc + 2.0);
	return acc;
}
