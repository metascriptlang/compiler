// @stdout: typed sampler2D@glsl.ms literal sampler2D@glsl.ms local helper@lib.ms|40
import { probe, callBound } from "./lib";
import { sampler2D } from "./glsl";

function body(): int32 { return sampler2D(1); }

console.log(probe(body) + "|" + String(callBound(body)));
