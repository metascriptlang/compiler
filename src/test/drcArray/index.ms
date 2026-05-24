// DRC Array Destroy Test Suite
//
// Tests the analyzer's classifyArray() routing logic by inspecting
// emitted C code for the destroy function name chosen per element type.
// Baseline scenarios MUST stay GREEN through all Phase G changes. BUG #3
// family scenarios go from RED (current) to GREEN (post-G2/G3/G4 fixes).

import "./helpers";
import "./scenarios/baseline";
import "./scenarios/bug3Family";
