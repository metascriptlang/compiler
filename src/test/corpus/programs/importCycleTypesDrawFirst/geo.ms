import { Scene } from "./scene";

export interface Geo { owner: Scene | null; peers: Vec<Scene>; v: int32; }
