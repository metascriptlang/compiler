// Every test of the native MetaScript crypto port that runs on both backends: `msc test std/crypto/pure/portTests.ms --tests-in-dir`
// from the repository root (the Wycheproof readers open std/crypto/test/vectors/). The slow owners run from portSlowTests.ms.

import "./aesDiffTest";
import "./aesNativeTest";
import "./aesWycheproofTest";
import "./argon2NativeTest";
import "./blake2bNativeTest";
import "./chachaDiffTest";
import "./chachaNativeTest";
import "./chachaWycheproofTest";
import "./coreNativeDiffTest";
import "./coreNativeTest";
import "./curve25519MathTest";
import "./ecNativeTest";
import "./ed25519DifferentialTest";
import "./ed25519NativeTest";
import "./ed25519WycheproofTest";
import "./ffTest";
import "./kdfDifferentialTest";
import "./kdfNativeTest";
import "./kdfWycheproofTest";
import "./legacyHashNativeTest";
import "./pcurveDiffTest";
import "./pcurveTest";
import "./rsaDifferentialTest";
import "./rsaNativeTest";
import "./rsaWycheproofTest";
import "./sha2DiffTest";
import "./sha2NativeTest";
