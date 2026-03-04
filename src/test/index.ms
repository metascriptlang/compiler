// E2E Cross-Phase Integration Tests
//
// Tests full pipeline: MetaScript source → C/JS output.
// Catches regressions spanning phase boundaries.
//
// Run: bun run test-ms src/test/index.ms

import "./helpers";
import "./c/variables";
import "./c/functions";
import "./c/classes";
import "./c/control";
import "./c/strings";
import "./c/expressions";
import "./c/closures";
import "./c/result";
import "./js/basic";
import "./js/result";
