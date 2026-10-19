import { Scene, sceneSize } from "./scene";

export struct Ctx { n: int32; }

export function make(n: int32): Ctx { return { n: n }; }

export function drawScene(s: Scene): int32 { return sceneSize(s); }
