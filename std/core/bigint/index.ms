when (!bare && !solana) {
	export { toString, BigInt, asIntN, asUintN } from "./kernel";
	@include("runtime/bigint/bigint.h");
}
