import { createFileSystemProvider, loadModuleGraph, canonicalModulePath } from "../../module/loader";
import { cwd } from "std/process";

test "VM layout metadata does not import the compiler AST" {
	const graph = loadModuleGraph(canonicalModulePath(`${cwd()}/src/raiser/layout.ms`), createFileSystemProvider());
	assert graph.errors.length == 0, graph.errors.join("\n");
	assert !graph.modulePaths.includes(canonicalModulePath(`${cwd()}/src/ast/node.ms`)), "layout metadata imports compiler AST";
}

test "typed VM memory does not import the compiler AST" {
	const graph = loadModuleGraph(canonicalModulePath(`${cwd()}/src/raiser/memory.ms`), createFileSystemProvider());
	assert graph.errors.length == 0, graph.errors.join("\n");
	assert !graph.modulePaths.includes(canonicalModulePath(`${cwd()}/src/ast/node.ms`)), "typed memory imports compiler AST";
}
