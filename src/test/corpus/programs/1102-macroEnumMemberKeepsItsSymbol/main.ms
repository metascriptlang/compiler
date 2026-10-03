// @stdout: Second First 1 Dark Light
// @exit: 0
// note: a checked enum member is an identifier spelled with a mangled name that no scope declares. Returned unchanged through a Node macro it comes back by its symbol, as a bare declaration initializer, as a call argument typed by the enum, as an array element and when the macro and the enum live in another module. It used to come back as "Undefined variable 'Flavor_Second'".

import { Node } from "std/meta";
import { passThrough, Shade } from "./decl";

enum Flavor { First, Second }
macro copyEnum(value: Node): Node { return value; }

function useFlavor(value: Flavor): string { return value.toString(); }

const copied = copyEnum(Flavor.Second);
const viaCall = useFlavor(copyEnum(Flavor.First));
const inArray: Flavor[] = [copyEnum(Flavor.Second)];
const dark: Shade = passThrough(Shade.Dark);
const light: Shade = passThrough(Shade.Light);
console.log(copied.toString() + " " + viaCall + " " + (inArray[0] as number).toString() + " " + dark.toString() + " " + light.toString());
