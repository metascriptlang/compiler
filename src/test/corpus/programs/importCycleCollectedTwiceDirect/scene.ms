import { SkinGeo } from "./skinGeo";
import { MeshId } from "./draw";

export struct Instance { mesh: MeshId; skin: SkinGeo; }

export interface Scene { meshes: Vec<Instance>; }

export function create(): Scene { return { meshes: [] }; }

export function isLive(s: Scene, n: int32): boolean { return s.meshes.length > n; }
