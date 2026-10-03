// Aggregate for the js/ tier — one entry per file, so a lane can run the tier
// with a single `msc test`.

import "./sizeof";
import "./basic";
import "./result";
import "./int64Literal";
import "./awaitOperand";
import "./concurrencyBoundary";
import "./testSuspension";
import "./accessCheck";
import "./float32";
import "./intConv";
import "./asConversion";
import "./downConversion";
import "./genericClassInstance";
import "./aliasNarrowingCast";
