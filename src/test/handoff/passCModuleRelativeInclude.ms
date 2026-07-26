// passCModuleRelativeInclude — a `./` or `../` include dir in @passC resolves
// against the DECLARING module's directory, not the process CWD.
//
// @compile("./x.c"), @include (auto -iquote<modDir>) and @link all resolve
// module-relative; @passC was the lone path-bearing directive that did not, so
// its dir was only ever found when the build happened to run from the right
// CWD. A module carrying `@passC("-Ideps/foo")` therefore compiled in its own
// project and broke the moment another project imported it — neon importing
// void/src/sokol/gpu.ms hit exactly this ('sokol_gfx.h' file not found).
//
// RED MEANS: the include dir went back to CWD-relative — this file fails to
// BUILD with "'passcRelDot.h' file not found" whenever the battery runs from
// anywhere but the fixture's own directory.

import { relDot, relDotDot } from "./fixtures/passCRelInclude/mod";

test "@passC -I./dir resolves against the declaring module" {
	assert relDot() === 42, "header under the module's own subdir";
}

test "@passC -I../dir resolves against the declaring module" {
	assert relDotDot() === 7, "header beside the module's parent";
}
