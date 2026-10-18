import { isLive } from "./scene";
import { SkinPose } from "./skinPose";

export interface SkinGeo { pose: SkinPose; }

export function ready(g: SkinGeo): boolean { return isLive(g.pose.scene, 0); }
