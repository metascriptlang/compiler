// @stdout: types 7
// note: the same cycle as importCycleTypesSceneFirst entered through draw, so the order of the entry's imports changes no meaning.
import { make, drawScene } from "./draw";
import { create } from "./scene";

console.log(`types ${drawScene(create(make(7)))}`);
