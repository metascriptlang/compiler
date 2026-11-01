// RSA: a 1024-bit private key is refused on import, a sha1 signature is refused while sha256 signs.
//
// @stdout: import1024 false
// @stdout: sign sha1 false sha256 true
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { RsaPrivateKey, sign } from "std/crypto/rsa";

const weakPem = `-----BEGIN PRIVATE KEY-----
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAJukLkvg4THhJXDH
tEBaCLE6AKtTYdYroROMzpemc4AsQtOsOQvLCH2XNPfUgjOV/uce7TLJ1o5aneIb
8aHthtCkaMjVtH31WL1C24SVObj1R6/v0EJfMTsLMsJ3bUgjg9Foh91exYFfhzyU
ioYIZmEJnaWNfUj8jfFQazSHeJ+/AgMBAAECgYAfxfWZkfAHIcJl8q7ukDLEE2Y9
k4keksuQVSd7uAROPzrpQXhn2uwBz5OFoIFwDIf8IMklnCTL7N3cYf4DI51ouxEG
qXzBQ8m9Ro6Wh3NKkvatPVTZa7QPGKrkBnT7Kbqzm0xBWRtAMpbFWPcK/lu4NFXG
hwDu84WO4OX8nl7ZeQJBAMy0VIp6aUQO4DAxbW0QwzWQ+IOUEavN1ufqnFOYeLwg
tRVOmdEw1Tl/aRzp9JlbYdQSzirTWaoP301Eki272AMCQQDCpHtwuPJzWaX1wT3T
r0101fWNX9LHOLS8x1xcQjpylVnwJegVWPKuZwpUswidWpXkWu5ojGRg0H51LP7+
JqKVAkBiI+KUMXPeSTN6Z3gK3gp41/QNQSPntlvd/EDOYz8fEp8+g9yCymKvmkIO
tquqCoGwZwOozIMkYU+xf7qFapV5AkApq+tdq8sElSnp3pBtFLgBjpk+xkgrLOHN
FOWaPveidoVF2+e/QkbavebBUX9DqRQ0Sp+GNKB89cZNMe/5262tAkAvtdh7x1+H
IA9Vrm6JJ2FHuLVd+6rPRxmrHK5ipK1LdpoBAZCb4ZfbVhSp1PTfgQrhyvLvM3dv
fp2S1xNEDI5h
-----END PRIVATE KEY-----
`;
const weak = await RsaPrivateKey.importPem(weakPem);
console.log("import1024", weak.ok);

const generated = await RsaPrivateKey.generate(2048);
if (!generated.ok) throw new Error("RsaPrivateKey.generate failed");
const key = generated.value;
console.log("sign sha1", (await sign(key, "msg", "sha1")).ok, "sha256", (await sign(key, "msg", "sha256")).ok);
