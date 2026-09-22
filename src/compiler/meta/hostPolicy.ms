import { RaiserValue } from "../../raiser/value";
import { RaiserVM, vmCallFunction } from "../../raiser/vm";
import { canonicalModulePath } from "../../module/loader";
import { cacheRoot } from "../package/cache";

function isPathInsideRoot(path: string, root: string): boolean {
	if (path.length <= root.length || !path.startsWith(root)) return false;
	const separator = path.charAt(root.length);
	return separator == "/" || separator == "\\";
}

export function restrictedComptimeSource(modulePath: string): string {
	const root = cacheRoot();
	if (root == "" || modulePath == "") return "";
	const canonicalRoot = canonicalModulePath(root);
	const canonicalSource = canonicalModulePath(modulePath);
	return isPathInsideRoot(canonicalSource, canonicalRoot) ? canonicalSource : "";
}

export function callWithComptimeHostPolicy(
	vm: RaiserVM,
	funcIdx: number,
	args: RaiserValue[],
	modulePath: string,
): RaiserValue {
	const previousRestricted = vm.hostCallsRestricted;
	const previousSource = vm.hostPolicySource;
	const restrictedSource = restrictedComptimeSource(modulePath);
	vm.hostCallsRestricted = restrictedSource != "";
	vm.hostPolicySource = restrictedSource;
	const result = vmCallFunction(vm, funcIdx, args);
	vm.hostCallsRestricted = previousRestricted;
	vm.hostPolicySource = previousSource;
	return result;
}

test "cache path boundary requires a separator" {
	assert isPathInsideRoot("/home/me/.metascript/cache/extracted/p/index.ms", "/home/me/.metascript/cache");
	assert !isPathInsideRoot("/home/me/.metascript/cache-copy/p/index.ms", "/home/me/.metascript/cache");
	assert !isPathInsideRoot("/home/me/.metascript/cache", "/home/me/.metascript/cache");
}

test "cached dependency module is a restricted compile-time source" {
	const root = cacheRoot();
	assert restrictedComptimeSource(root + "/extracted/p@1.0.0/index.ms") != "";
	assert restrictedComptimeSource(root + "-copy/extracted/p@1.0.0/index.ms") == "";
}
