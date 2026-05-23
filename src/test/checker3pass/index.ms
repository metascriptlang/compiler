// 3-pass Checker Isolation Test Suite
//
// Tests Pass 1 (collect) → Pass 2 (resolve) → Pass 3 (check) INVARIANTS
// directly on the post-check AST, without depending on transform / mono /
// codegen. Each scenario asserts:
//   1. No checker errors for valid programs
//   2. No GenericParam leakage in nodeType outside template decls
//   3. Specific node.nodeType structure matches expectation
//
// Scenarios are organized by the "source of binding" they exercise:
//   - explicit type args (`f<int32>(...)`)
//   - inferred from concrete leading args (`f(4, 1, arrow)`)
//   - inferred from backward expectedType (`let r: X = f<T>(...)`)
//   - generic methods, constructors, nested calls
//   - legitimate limitations (closure-first without hint)

import "./helpers";
import "./invariant";
import "./scenarios/explicitTypeArgs";
import "./scenarios/inferredFromArgs";
import "./scenarios/inferredFromReturn";
import "./scenarios/genericMethod";
import "./scenarios/genericConstructor";
import "./scenarios/nestedGeneric";
import "./scenarios/recursive";
import "./scenarios/overloadXGeneric";
import "./scenarios/limitations";
import "./stress/deepNesting";
import "./stress/manyParams";
import "./stress/mixed";
