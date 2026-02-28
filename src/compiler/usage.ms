// MetaScript Compiler CLI — Version and usage display

import { bold, cyan, yellow, dim, green } from "../utils/color";

export const VERSION = "0.1.0";

export function printUsage(): void {
	console.log("");
	console.log(bold("Metascript Compiler") + " " + dim("(msc)") + " " + green("v" + VERSION));
	console.log("");
	console.log(yellow("USAGE:"));
	console.log("  msc " + dim("[COMMAND]") + " <file.ms> " + dim("[OPTIONS]"));
	console.log("");
	console.log(yellow("COMMANDS:"));
	console.log("  " + cyan("compile") + " <file>        Compile to target backend");
	console.log("  " + cyan("run") + " <file>            Compile and run");
	console.log("  " + cyan("test") + " <file>           Run tests");
	console.log("  " + cyan("check") + " <file>          Type check only (no codegen)");
	console.log("  " + cyan("build") + "                 Build using build.ms config");
	console.log("");
	console.log(yellow("VISIBILITY/DEBUGGING:"));
	console.log("  " + cyan("dump-tokens") + " <file>    Show tokenization output");
	console.log("  " + cyan("dump-ast") + " <file>       Show parsed AST");
	console.log("  " + cyan("pipeline") + " <file>       Show compilation pipeline stages");
	console.log("");
	console.log(yellow("OPTIONS:"));
	console.log("  " + cyan("-h") + ", " + cyan("--help") + "            Display this help");
	console.log("  " + cyan("-v") + ", " + cyan("--version") + "         Show version");
	console.log("  " + cyan("--target") + "=<c|js>       Target backend " + dim("(default: c)"));
	console.log("  " + cyan("--output") + "=<file>       Output file path");
	console.log("  " + cyan("-t") + ", " + cyan("--time") + "            Show compilation timing");
	console.log("  " + cyan("--verbose") + "             Verbose phase output");
	console.log("  " + cyan("--error-max") + "=<N>       Stop after N errors " + dim("(0 = all)"));
	console.log("  " + cyan("--colors") + "=<on|off>     Force color output on/off");
	console.log("  " + cyan("--no-color") + "            Disable color output");
	console.log("");
	console.log(yellow("EXAMPLES:"));
	console.log("  msc compile hello.ms                    " + dim("# Compile to C (default)"));
	console.log("  msc compile --target=js main.ms         " + dim("# Compile to JavaScript"));
	console.log("  msc run fibonacci.ms                    " + dim("# Build and run"));
	console.log("  msc test src/index.ms                   " + dim("# Run tests"));
	console.log("  msc check src/index.ms                  " + dim("# Type check only"));
	console.log("  msc dump-ast hello.ms                   " + dim("# Show AST"));
	console.log("  msc pipeline hello.ms                   " + dim("# Show all pipeline stages"));
	console.log("");
}
