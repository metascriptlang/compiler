// A type a C header declares is one type in every module that imports the header: a handle, a
// struct and an enum made in one module pass to a function of another, and a module one directory
// down that reaches the header through `..` passes the same types.
// @stdout: 1 6 1|10 0
// @exit: 0

import { Shape, Size, ShapeKind } from "./shape.h";
import { handleState, area, kindCode } from "./take";
import { farArea, farKind } from "./sub/far";

const none: Shape | null = null;
const size: Size = { w: 3, h: 2 };
console.log(`${handleState(none)} ${area(size)} ${kindCode(ShapeKind.SHAPE_ROUND)}|${farArea()} ${farKind()}`);
