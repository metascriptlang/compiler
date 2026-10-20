export enum ProjectionKind { Orthographic, Perspective }

export struct Projection = match (kind: ProjectionKind) {
	ProjectionKind.Orthographic => { worldPerTexel: float32, snap: boolean },
	ProjectionKind.Perspective => { fovY: float32 },
};

export function `==`(this a: Projection, b: Projection): boolean {
	if (a.kind == ProjectionKind.Perspective && b.kind == ProjectionKind.Perspective) return a.fovY == b.fovY;
	if (a.kind == ProjectionKind.Orthographic && b.kind == ProjectionKind.Orthographic) return a.worldPerTexel == b.worldPerTexel && a.snap == b.snap;
	return false;
}
