// @stdout: types 7
// note: the entry imports scene before draw, so scene's module is checked before the module that draws it, and a back-edge type (the Scene held by Geo as nullable and as Vec element) reaches draw through the first phase's placeholder. Before, the cycle's declarations were rebuilt as new types in the second phase, and draw kept the placeholder: "unresolved type (kind=48) reached codegen".
import { create } from "./scene";
import { make, drawScene } from "./draw";

console.log(`types ${drawScene(create(make(7)))}`);
