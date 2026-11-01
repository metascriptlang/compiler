// @stdout: 1 b 0.5 14 14
import * as StyleSheet from "./sheet";
import { twice } from "./sheet";

const s = StyleSheet.create({ a: 1, b: "b" });
const n = 7;
console.log(s.a, s.b, StyleSheet.hairlineWidth, StyleSheet.twice(n), twice(n));
