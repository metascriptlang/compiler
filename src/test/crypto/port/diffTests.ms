// The port against the vendored oracle (src/test/crypto/oracle) on both backends: `msc test
// src/test/crypto/port/diffTests.ms --tests-in-dir` from the repository root.

import "./aesDiffTest";
import "./chachaDiffTest";
import "./coreNativeDiffTest";
import "./ed25519DifferentialTest";
import "./kdfDifferentialTest";
import "./pcurveDiffTest";
import "./rsaDifferentialTest";
import "./sha2DiffTest";
