// MetaScript Compiler CLI — Version and usage display

export const VERSION = "0.1.0";

export function printUsage(): void {
	console.log("");
	console.log("Metascript Compiler (msc) v" + VERSION);
	console.log("");
	console.log("USAGE:");
	console.log("  msc [COMMAND] <file.ms> [OPTIONS]");
	console.log("");
	console.log("COMMANDS:");
	console.log("  compile <file>        Compile to target backend");
	console.log("  run <file>            Compile and run");
	console.log("  test <file>           Run tests");
	console.log("  check <file>          Type check only (no codegen)");
	console.log("  build                 Build using build.ms config");
	console.log("");
	console.log("VISIBILITY/DEBUGGING:");
	console.log("  dump-tokens <file>    Show tokenization output");
	console.log("  dump-ast <file>       Show parsed AST");
	console.log("  pipeline <file>       Show compilation pipeline stages");
	console.log("");
	console.log("OPTIONS:");
	console.log("  -h, --help            Display this help");
	console.log("  -v, --version         Show version");
	console.log("  --target=<c|js>       Target backend (default: c)");
	console.log("  --output=<file>       Output file path");
	console.log("");
	console.log("EXAMPLES:");
	console.log("  msc compile hello.ms                    # Compile to C (default)");
	console.log("  msc compile --target=js main.ms         # Compile to JavaScript");
	console.log("  msc run fibonacci.ms                    # Build and run");
	console.log("  msc test src/index.ms                   # Run tests");
	console.log("  msc check src/index.ms                  # Type check only");
	console.log("  msc dump-ast hello.ms                   # Show AST");
	console.log("  msc pipeline hello.ms                   # Show all pipeline stages");
	console.log("");
}
