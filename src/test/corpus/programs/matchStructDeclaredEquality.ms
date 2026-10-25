// Parity program — a match struct compares only through the `==` declared for it: directly,
// through a generic parameter, as a struct field the value fold reaches, and on a
// boolean-discriminated arm; `!=` and `!==` are that `==` negated.
//
// @stdout: direct=true,false,true,false,false,true
// @stdout: generic=true,false,false,true
// @stdout: field=true,false,false,true
// @stdout: bool=true,false,true
// @exit: 0

enum ProjectionKind { Orthographic, Perspective }

struct Projection = match (kind: ProjectionKind) {
	ProjectionKind.Orthographic => { worldPerTexel: float32, snap: boolean },
	ProjectionKind.Perspective => { fovY: float32 },
};

export function `==`(this a: Projection, b: Projection): boolean {
	if (a.kind == ProjectionKind.Perspective && b.kind == ProjectionKind.Perspective) return a.fovY == b.fovY;
	if (a.kind == ProjectionKind.Orthographic && b.kind == ProjectionKind.Orthographic) return a.worldPerTexel == b.worldPerTexel && a.snap == b.snap;
	return false;
}

struct Camera { zoom: int32, projection: Projection }

struct Reply = match (ok: boolean) {
	true => { value: int32 },
	false => { reason: string },
};

export function `==`(this a: Reply, b: Reply): boolean {
	if (a.ok && b.ok) return a.value == b.value;
	if (!a.ok && !b.ok) return a.reason == b.reason;
	return false;
}

function same<T>(a: T, b: T): boolean { return a === b; }
function differ<T>(a: T, b: T): boolean { return a !== b; }

const first: Projection = { kind: ProjectionKind.Perspective, fovY: 1.0 };
const second: Projection = { kind: ProjectionKind.Perspective, fovY: 1.0 };
const wider: Projection = { kind: ProjectionKind.Perspective, fovY: 2.0 };
const ortho: Projection = { kind: ProjectionKind.Orthographic, worldPerTexel: 0.1, snap: false };
console.log(`direct=${first == second},${first == ortho},${first === second},${first != second},${first !== second},${first !== wider}`);
console.log(`generic=${same<Projection>(first, second)},${same<Projection>(first, ortho)},${differ<Projection>(first, second)},${differ<Projection>(first, wider)}`);

const near: Camera = { zoom: 1, projection: first };
const nearAgain: Camera = { zoom: 1, projection: second };
const far: Camera = { zoom: 1, projection: ortho };
console.log(`field=${near == nearAgain},${near == far},${near != nearAgain},${near != far}`);

const yes: Reply = { ok: true, value: 3 };
const yesAgain: Reply = { ok: true, value: 3 };
const no: Reply = { ok: false, reason: "x" };
console.log(`bool=${yes == yesAgain},${yes == no},${yes != no}`);
