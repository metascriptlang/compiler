// Fmt roundtrip suite.
//
// Each test in here asserts: parse(source) and parse(fmt(source)) produce
// the same AST shape. If a test fails, fmt corrupted the program — usually
// by dropping parens or reordering tokens around an operator.
//
// Add new cases as standalone files (cases/<topic>.ms) and import them here.

import "./roundtrip";

// Per-case fixtures (one file per parens/precedence concern).
import "./cases/typeAssertionMember";
import "./cases/typeAssertionArray";
import "./cases/typeAssertionNew";
import "./cases/binaryMember";
import "./cases/binaryPrecedence";
import "./cases/conditionalMember";
import "./cases/unaryMember";
import "./cases/arrowCallee";
import "./cases/typeAssertionInner";
import "./cases/unaryOperand";
import "./cases/reExport";
import "./cases/typeAliasGenerics";
import "./cases/functionGenerics";
import "./cases/classInterfaceGenerics";
import "./cases/templateLiteral";
import "./cases/newGenericArgs";
import "./cases/defaultParams";
import "./cases/starExportImport";
import "./cases/unreachableStmt";
import "./cases/testDeclEscape";
import "./cases/propertyInit";
import "./cases/inlineShortBlock";
import "./cases/inlineImport";
import "./cases/enumComment";
import "./cases/standaloneComment";
import "./cases/interfaceFieldComment";
import "./cases/classFieldComment";
import "./cases/propertyVisibility";
import "./cases/methodVisibility";
import "./cases/bigIntRegex";
import "./cases/missingPrinters";
import "./cases/asyncFlags";
import "./cases/awaitYieldAtom";
import "./cases/assertEscape";
import "./cases/externFunction";
import "./cases/tryExprAtom";
import "./cases/methodDefaults";
