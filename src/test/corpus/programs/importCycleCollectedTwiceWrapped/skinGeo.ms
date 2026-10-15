import { isLive } from "./scene";
import { SkinPose } from "./skinPose";

export interface SkinGeo { pose: SkinPose; }

export function ready(g: SkinGeo): boolean { const s = g.pose.scene; return s !== null && isLive(s, 0); }
