import { dynamicListText, nmFunctions } from "./sanitizerSyms";

let cases: int32 = 0;

function expect(condition: boolean, what: string): void {
	cases += 1;
	if (!condition) { throw new Error("failed: " + what); }
}

const NM = [
	"",
	"ubsan_minimal_handlers.cpp.o:",
	"0000000000000000 T __ubsan_handle_add_overflow_minimal",
	"0000000000000010 W __sanitizer_report_error_summary",
	"0000000000000020 t local_helper",
	"                 U abort",
	"0000000000000030 D __ubsan_data",
	"0000000000000040 T plain_global",
].join("\n");

function run(): void {
	const functions = nmFunctions(NM);
	expect(functions.join(",") == "__ubsan_handle_add_overflow_minimal," +
		"__sanitizer_report_error_summary,plain_global",
		"global T and W symbols are functions; local, undefined and data are not");
	const list = dynamicListText(functions, ["__ubsan_*", ""]);
	expect(list.ok && list.value ==
		"{\n  __sanitizer_report_error_summary;\n  __ubsan_*;\n};\n",
		"interface functions and the extra patterns are exported, sorted");
	const interceptor = dynamicListText(["__interceptor_malloc"], []);
	expect(!interceptor.ok && interceptor.error.contains("not ported"),
		"an interceptor archive is refused rather than listed without its rule");
	expect(!dynamicListText(["_Znwm"], []).ok,
		"operator new is refused rather than listed without its rule");
	console.log("sanitizerSyms: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
