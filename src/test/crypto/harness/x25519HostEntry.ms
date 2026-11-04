// The export lives here, not in a kernel module: a size measurement of a kernel must not root this symbol.
when (x25519Impl == "monocypher") {
	@include("vendor/monocypher/src/monocypher.h");
	@compile("vendor/monocypher/src/monocypher.c");
	@passC("-Ivendor/monocypher/src");
	extern function crypto_x25519(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void;
}

when (x25519Impl == "pilot") {
	import { x25519ScalarMult as pilotX25519ScalarMult } from "std/crypto/x25519/pilot";
}

when (x25519Impl == "pure") {
	import { x25519 as pureX25519 } from "std/crypto/pure/x25519";
}

@exportName("x25519ScalarMult")
function hostX25519ScalarMult(output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>): void {
	when (x25519Impl == "monocypher") {
		crypto_x25519(output, scalar, point);
	} else when (x25519Impl == "pilot") {
		pilotX25519ScalarMult(output, scalar, point);
	} else when (x25519Impl == "pure") {
		const scalarArr = new Array<uint8>(32);
		const pointArr = new Array<uint8>(32);
		for (let i = 0; i < 32; i++) {
			scalarArr[i] = scalar[i];
			pointArr[i] = point[i];
		}
		const result = pureX25519(scalarArr, pointArr);
		for (let i = 0; i < 32; i++) output[i] = result[i];
	} else when (x25519Impl == "noop") {
	} else when (x25519Impl == "leakyBranch") {
		const rounds = (scalar[0] & 15) as int32;
		let acc: uint8 = 0;
		for (let r = 0; r < rounds; r += 1) {
			acc = acc + point[r];
		}
		for (let i = 0; i < 32; i += 1) {
			output[i] = point[i] ^ acc;
		}
	} else when (x25519Impl == "leakyIndex") {
		for (let i = 0; i < 32; i += 1) {
			output[i] = point[(scalar[i] & 31) as int32];
		}
	} else {
		x25519ImplIsNotOneOfMonocypherPilotPureNoopLeakyBranchLeakyIndex();
	}
}
