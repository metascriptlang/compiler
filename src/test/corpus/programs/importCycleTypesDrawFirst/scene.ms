import { Geo } from "./geo";
import { Ctx } from "./draw";

export interface Scene {
	readonly ctx: Ctx;
	geo: Geo | null;
}

export function create(ctx: Ctx): Scene { return { ctx: ctx, geo: null }; }

export function sceneSize(s: Scene): int32 { return s.ctx.n; }
