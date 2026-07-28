// Unified Test Suite
//
// Run all: msc test src/test/index.ms
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
import "./lang/discrim";
import "./lang/json";
import "./lang/trycatch";
import "./lang/recursion";
import "./lang/advanced";
import "./lang/async";
// comptime.ms runs end-to-end via `msc test src/test/lang/comptime.ms`;
// regression-prevention guard for the underlying buildExportInfo behavior
// lives in fixedbugs/bug028.ms.
// import "./lang/comptime";
import "./lang/syntax";
import "./lang/multimod/main";

// -- regression suite (one file per fixed bug) --
import "./fixedbugs/index";

// -- formatter roundtrip (parse(src) === parse(fmt(src))) --
import "./fmt/index";

// -- E2E pipeline tests --
import "./c/variables";
import "./c/functions";
import "./c/classes";
import "./c/control";
import "./c/strings";
import "./c/expressions";
import "./c/closures";
import "./c/result";
import "./c/jsx";
import "./c/buffer";
import "./c/httpServer";
import "./c/actor";
import "./c/json";
import "./c/protocols";
import "./c/typeIntrospection";
import "./c/multidecl";
import "./c/toycodec";
import "./c/drcLifecycle";
import "./js/basic";
import "./js/result";

// -- phase handoff tests --
import "./handoff/index";

// -- 3-pass checker isolation tests (Phase F infrastructure) --
import "./checker3pass/index";
