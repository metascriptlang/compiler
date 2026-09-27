// @stdout: branches 0 0 1 1

let constructions: int32 = 0;
let visits: int32 = 0;
class Point {
	x: int32;
	y: int32;
	constructor(x: int32, y: int32) { constructions += 1; this.x = x; this.y = y; }
}
function tally(point: Point): boolean { visits += 1; return point.x > 0; }
function run(): void {
	if (false && tally(new Point(1, 2))) { visits += 100; }
	if (false) { tally(new Point(1, 2)); }
	for (let i = 0; i < 1; i += 1) {
		if (false && tally(new Point(1, 2))) { visits += 100; }
	}
	const deadConstructions = constructions;
	const deadVisits = visits;
	if (true && tally(new Point(1, 2))) { }
	console.log(`branches ${deadConstructions} ${deadVisits} ${constructions} ${visits}`);
}
run();
