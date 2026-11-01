#!/usr/bin/env python3
# Generates x25519Rfc7748.json: raw X25519 cases from a bigint reference ladder (RFC 7748 section 5).
# Every non-zero output must equal `openssl pkeyutl -derive`; an all-zero output must be refused
# by OpenSSL or derived as zeros. Any other OpenSSL refusal or mismatch aborts the generation.
# Usage: python3 -I x25519Rfc7748Gen.py > x25519Rfc7748.json
import json
import subprocess
import sys
import tempfile
import os

P = 2**255 - 19
A24 = 121665


def decode_scalar(k):
	b = bytearray(k)
	b[0] &= 248
	b[31] &= 127
	b[31] |= 64
	return int.from_bytes(b, "little")


def decode_u(u):
	b = bytearray(u)
	b[31] &= 127
	return int.from_bytes(b, "little") % P


def ladder(k, u):
	x1, x2, z2, x3, z3, swap = u, 1, 0, u, 1, 0
	for t in range(254, -1, -1):
		kt = (k >> t) & 1
		swap ^= kt
		if swap:
			x2, x3, z2, z3 = x3, x2, z3, z2
		swap = kt
		a = (x2 + z2) % P
		aa = a * a % P
		b = (x2 - z2) % P
		bb = b * b % P
		e = (aa - bb) % P
		c = (x3 + z3) % P
		d = (x3 - z3) % P
		da = d * a % P
		cb = c * b % P
		x3 = (da + cb) ** 2 % P
		z3 = x1 * (da - cb) ** 2 % P
		x2 = aa * bb % P
		z2 = e * (aa + A24 * e) % P
	if swap:
		x2, x3, z2, z3 = x3, x2, z3, z2
	return x2 * pow(z2, P - 2, P) % P


def x25519(scalar, point):
	return ladder(decode_scalar(scalar), decode_u(point)).to_bytes(32, "little")


def openssl_derive(scalar, point):
	with tempfile.TemporaryDirectory() as tmp:
		priv, pub = os.path.join(tmp, "k.der"), os.path.join(tmp, "p.der")
		with open(priv, "wb") as f:
			f.write(bytes.fromhex("302e020100300506032b656e04220420") + scalar)
		with open(pub, "wb") as f:
			f.write(bytes.fromhex("302a300506032b656e032100") + point)
		return subprocess.run(
			["openssl", "pkeyutl", "-derive", "-inkey", priv, "-keyform", "DER",
			 "-peerkey", pub, "-peerform", "DER"],
			capture_output=True,
		)


def le(n, bits=256):
	return (n % (1 << bits)).to_bytes(32, "little")


BASE = le(9)
S = [
	bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
	bytes.fromhex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
	bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
	bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"),
]
U = [
	bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
	bytes.fromhex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
	bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
	bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"),
]
HIGH = bytes([0x80])


def with_bit255(u):
	return u[:31] + bytes([u[31] | 0x80])


cases = []


def add(group, comment, scalar, point):
	cases.append((group, comment, scalar, point))


# RFC 7748 section 5.2 and 6.1 known answers (scalar, point as printed in the RFC)
add("Rfc7748Ktv", "RFC 7748 5.2 first vector", S[0], U[0])
add("Rfc7748Ktv", "RFC 7748 5.2 second vector (point has bit 255 set)", S[1], U[1])
add("Rfc7748Ktv", "RFC 7748 6.1 alice public key", S[2], BASE)
add("Rfc7748Ktv", "RFC 7748 6.1 bob public key", S[3], BASE)
add("Rfc7748Ktv", "RFC 7748 6.1 shared secret alice side", S[2], U[3])
add("Rfc7748Ktv", "RFC 7748 6.1 shared secret bob side", S[3], U[2])

# Scalar clamp axes: the low three bits, bit 254 and bit 255 of the scalar must not change the result
for i, s in enumerate(S[:3]):
	b = bytearray(s)
	low = bytearray(s)
	low[0] = (low[0] & 0xF8) | 0x05
	add("ScalarClamp", f"scalar {i} low three bits set", bytes(low), U[i])
	hi = bytearray(s)
	hi[31] |= 0x80
	add("ScalarClamp", f"scalar {i} bit 255 set", bytes(hi), U[i])
	nofour = bytearray(s)
	nofour[31] &= 0xBF
	add("ScalarClamp", f"scalar {i} bit 254 cleared", bytes(nofour), U[i])
	allbits = bytearray(s)
	allbits[0] |= 0x07
	allbits[31] = (allbits[31] | 0x80) & 0xBF
	add("ScalarClamp", f"scalar {i} all clamp bits perturbed", bytes(allbits), U[i])
add("ScalarClamp", "scalar all zero", bytes(32), U[0])
add("ScalarClamp", "scalar all ones", bytes([0xFF] * 32), U[0])
add("ScalarClamp", "scalar all ones base point", bytes([0xFF] * 32), BASE)

# High bit of the point: ignored (RFC 7748 section 5)
for i, u in enumerate(U):
	add("PointHighBit", f"point {i} with bit 255 flipped on", S[0], with_bit255(u[:31] + bytes([u[31] & 0x7F])))
	add("PointHighBit", f"point {i} with bit 255 cleared", S[0], u[:31] + bytes([u[31] & 0x7F]))
add("PointHighBit", "base point with bit 255 set", S[0], with_bit255(BASE))

# Non-canonical u (u >= p): reduced mod p (RFC 7748 sections 5 and 7)
for k in (0, 1, 2, 5, 9, 18):
	add("NonCanonicalPoint", f"point p+{k}", S[0], le(P + k, 255))
	add("NonCanonicalPoint", f"point p+{k} with bit 255 set", S[0], with_bit255(le(P + k, 255)))
add("NonCanonicalPoint", "point 2^255-1", S[0], le(2**255 - 1))
add("NonCanonicalPoint", "point 2^256-1", S[0], bytes([0xFF] * 32))

# Low-order points (orders 1, 2, 4, 8 and their encodings): raw output is all-zero
LOW = [
	le(0), le(1),
	bytes.fromhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
	bytes.fromhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
	le(P - 1), le(P), le(P + 1),
]
for i, u in enumerate(LOW):
	add("LowOrderPoint", f"low order encoding {i}", S[0], u)
	add("LowOrderPoint", f"low order encoding {i} with bit 255 set", S[1], with_bit255(u))

tests = []
checked = 0
refused = 0
for n, (group, comment, scalar, point) in enumerate(cases, 1):
	out = x25519(scalar, point)
	zero = out == bytes(32)
	r = openssl_derive(scalar, point)
	if zero:
		if r.returncode == 0 and r.stdout != out:
			sys.exit(f"case {n} ({comment}): openssl derived {r.stdout.hex()}, reference is all-zero")
		if r.returncode != 0:
			refused += 1
	else:
		if r.returncode != 0:
			sys.exit(f"case {n} ({comment}): openssl refused a non-zero case: {r.stderr.decode()}")
		if r.stdout != out:
			sys.exit(f"case {n} ({comment}): openssl {r.stdout.hex()} vs reference {out.hex()}")
		checked += 1
	tests.append({
		"tcId": n,
		"comment": comment,
		"flags": [group] + (["ZeroSharedSecret"] if zero else []),
		"public": point.hex(),
		"private": scalar.hex(),
		"shared": out.hex(),
		"result": "acceptable" if zero else "valid",
	})

nonzero = sum(1 for t in tests if t["shared"] != "00" * 32)
if checked != nonzero or checked + refused > len(tests) or checked < 40:
	sys.exit(f"oracle coverage: {checked} cross-checked of {nonzero} non-zero cases, {refused} all-zero refusals")

# RFC 7748 section 5.2 iterated results (also pinned in x25519Assurance.ms)
k = u = BASE
iterated = {}
for i in range(1, 1001):
	k, u = x25519(k, u), k
	if i in (1, 1000):
		iterated[i] = k.hex()

print(json.dumps({
	"algorithm": "XDH",
	"schema": "xdh_comp_schema_v1.json",
	"generator": "x25519Rfc7748Gen.py: RFC 7748 section 5 bigint ladder, openssl pkeyutl -derive cross-check",
	"opensslCrossChecked": checked,
	"opensslRefusedAllZero": refused,
	"iterated": {str(i): v for i, v in iterated.items()},
	"numberOfTests": len(tests),
	"testGroups": [{"type": "XdhComp", "curve": "curve25519", "tests": tests}],
}, indent=1))
