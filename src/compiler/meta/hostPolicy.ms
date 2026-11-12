import { RaiserValue } from "../../raiser/value";
import { RaiserVM, vmCallFunction } from "../../raiser/vm";
import { takeTouched, retouch } from "../../raiser/module";
import { canonicalModulePath } from "../../module/loader";
import { cacheRoot } from "../package/cache";
import { activeSystem } from "../../utils/system";

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

type EngineRunObserver = (vm: RaiserVM, ran: int32[]) => void;
let _runObserver: EngineRunObserver | null = null;

let _comptimeRuns: int32 = 0;

export function comptimeRunCount(): int32 {
	return _comptimeRuns;
}

export function observeComptimeRuns(observer: EngineRunObserver | null): EngineRunObserver | null {
	const previous = _runObserver;
	_runObserver = observer;
	return previous;
}

export function callWithComptimeHostPolicy(
	vm: RaiserVM,
	funcIdx: number,
	args: RaiserValue[],
	modulePath: string,
): RaiserValue {
	_comptimeRuns += 1;
	const previousRestricted = vm.hostCallsRestricted;
	const previousSource = vm.hostPolicySource;
	const previousSandboxed = vm.sandboxed;
	vm.sandboxed = activeSystem() != null;
	const restrictedSource = restrictedComptimeSource(modulePath);
	vm.hostCallsRestricted = restrictedSource != "";
	vm.hostPolicySource = restrictedSource;
	defer {
		vm.hostCallsRestricted = previousRestricted;
		vm.hostPolicySource = previousSource;
		vm.sandboxed = previousSandboxed;
	}
	const outer = takeTouched(vm.mod);
	const result = vmCallFunction(vm, funcIdx, args);
	const ran = takeTouched(vm.mod);
	retouch(vm.mod, outer);
	retouch(vm.mod, ran);
	const observer = _runObserver;
	if (observer != null) observer(vm, ran);
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

import { createVM } from "../../raiser/vm";
import { RaiserOpcode, RaiserInstruction, raiserABC } from "../../raiser/bytecode";
import { makeTestModule } from "../../raiser/module";
import { raiserConstString } from "../../raiser/value";
import { registerHostFn, HostCapability, _resetHostRegistryForTests, RaiserHostFn } from "../../raiser/hostRegistry";

test "a host call that throws leaves the host-policy flags as the caller set them" {
	_resetHostRegistryForTests();
	const refuse: RaiserHostFn = (args: RaiserValue[]): RaiserValue => { throw new Error("internal: test host call refused"); };
	registerHostFn("hostPolicyTestRefuse", refuse, HostCapability.Pure);
	const code: RaiserInstruction[] = [raiserABC(RaiserOpcode.CallHost, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const vm = createVM(makeTestModule(code, [raiserConstString("hostPolicyTestRefuse")]));
	vm.hostCallsRestricted = true;
	vm.hostPolicySource = "outer";
	vm.sandboxed = false;
	let thrown = false;
	try {
		callWithComptimeHostPolicy(vm, 0, [], "");
	} catch (e) {
		thrown = true;
	}
	_resetHostRegistryForTests();
	assert thrown;
	assert vm.hostCallsRestricted, "hostCallsRestricted was not restored";
	assert vm.hostPolicySource == "outer", "hostPolicySource was not restored";
	assert !vm.sandboxed, "sandboxed was not restored";
}
