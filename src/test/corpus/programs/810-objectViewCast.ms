// @stdout: iface=L write=M/M class=N alias=P pair=3M named=N
interface Circle { kind: string; r: number; label: string; }
class Box { w: number = 2; tag: string = "T"; name: string = "N"; }
type Pt = { x: number, y: number, id: string };
interface Named { name: string; }

function main(): void {
	const c: Circle = { kind: "circle", r: 3, label: "L" };
	const iface = (c as { label: string }).label;
	const v = c as { label: string };
	v.label = "M";
	const write = c.label + "/" + v.label;
	const cls = (new Box() as { name: string }).name;
	const p: Pt = { x: 1, y: 2, id: "P" };
	const alias = (p as { id: string }).id;
	const pair = c as { r: number, label: string };
	const named = (new Box() as Named).name;
	console.log("iface=" + iface + " write=" + write + " class=" + cls + " alias=" + alias + " pair=" + pair.r + pair.label + " named=" + named);
}
main();
