// Unified Test Suite
//
// Run all: bun run test-ms src/test/index.ms
//
// Structure:
//   lang/    — Language feature tests (runtime behavior)
//   c/       — E2E pipeline tests: MetaScript source → C output
//   js/      — E2E pipeline tests: MetaScript source → JS output

// -- helpers --
import "./helpers";

// -- language feature tests --
import "./lang/basics";
import "./lang/strings";
import "./lang/types";
import "./lang/match";
import "./lang/controlFlow";
import "./lang/closures";
import "./lang/closuresAdv";
import "./lang/interfaces";
import "./lang/classes";
import "./lang/result";
import "./lang/trycatch";
import "./lang/recursion";
import "./lang/advanced";
import "./lang/async";
import "./lang/syntax";
import "./lang/multimod/main";

// -- E2E pipeline tests --
import "./c/variables";
import "./c/functions";
import "./c/classes";
import "./c/control";
import "./c/strings";
import "./c/expressions";
import "./c/closures";
import "./c/result";
import "./c/buffer";
import "./c/drcLifecycle";
import "./js/basic";
import "./js/result";

// -- phase handoff tests --
import "./handoff/index";
