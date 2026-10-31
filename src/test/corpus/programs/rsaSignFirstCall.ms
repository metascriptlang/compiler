// A key imported from PEM signs and verifies as the first crypto call of the process: the sign and
// verify paths bring the crypto library up themselves, with no generate or encrypt before them.
//
// @stdout: first-call sign true verify true
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { rsaImportPrivate, rsaSign, rsaVerify, rsaFree } from "std/crypto/rsa";

const pem = [
	"-----BEGIN RSA PRIVATE KEY-----",
	"MIIEowIBAAKCAQEAwLGB/nbgGfFlcx/p6TTiITyMAqRja0KB1kkXYSA4DnuxqwyL",
	"MthtmNEXBXlCMYneRcH2kul0uQqhetY1PcdQf4BJx9IHzH9ZymE7m1BDHHdAgbxv",
	"RHIdlLoFBREOuoAZZ3N4xgPPN5DbVksK7AYHN1gx0/e08OrWKvT7v8Qb1AWtXZtj",
	"/rAw27nJsWOEL2bBpMe0rU4JjOha927vzJVcYCo/8p5ieY81YLGWz0EF9ccXHCtz",
	"tOdyW5KDBlKbufT+35DylNlUm9ISjcpFeCa99oia8xSqIoJEwt/4GRv74/CM+7Gs",
	"Ch6UM9zfEzTl5fS0nWiVHAERRd0YObpQhDlg0wIDAQABAoIBAEOiSmlhmjkg5KXq",
	"7rQ/LpvR36bRwl+UgXQQRZd+so5K1kqeZYFcO+OmiDkQna47oPvFH+Hi9Wg5lgJC",
	"i396pQOLqNntG3WowYBqbnyOSHAGX2rqE/fnQgDA5iAoI45Mhh4shpiiH6p2OrZo",
	"MpYza3b+isbGrAjftHpxcKeXktjw5BuutLtZtalvlFWc9g+hVI4XBbaNG33R5uOZ",
	"hTUl+ZRNtsTdgNcPnKDLrViGi7QZt2Y4f26IGM85/6g/P0iMxvaBkViY0eClV7Wb",
	"G7GNV128kyUrtnygMRv/ezOJrYk8HzYhVeL0mX10FEFV2IUGA9LqvJ2mxv1VHEpD",
	"t8jabuECgYEA+vQJuY/5MYF0+l1fGY5H6ffLHzqCc+725rxLnkHb6OgkxSeXO+Jl",
	"e00w45KLKF+C0r3Rsgf77FRVcwFZhYeVGmi5TchFSuG+Fck25Z+xAjkL5/gM/4hc",
	"nLiSeHMnVswGnDlDmbcGGepY/yPk3Hb3xL+VfBpO5lfD1t7xfsd9b+MCgYEAxJGJ",
	"Bmmzrk9K/TBHX0KWJ3z1az2tuZNVN6wxV9sQARInkSI1mGOhemnzA/br+N441QBj",
	"xsiJSMJ2quBhyENEiBzeqBpEkl/dNOF6zFtepxsuw6HjbFIReKxViuv1UqxSl6tP",
	"GXR9ADZ3lJkeF3JGuU1GbrqWqS0QuTtbKjTQPlECgYAtIH8zMDGmdlobv3ifdtd1",
	"ukp7diEJSfp6KXgLoFo0OrKKBYGLkj2fe5UEB1Eg1HQJA3tW4Vqq98tZ3+9CNMxa",
	"MGTKGO5k9c0hy8okZqAE/08lypRDyzikMgicwlBbqlqx8xY16RSeymZwkvrPrlEF",
	"v1HZPD3d7ABafkK9ApCK8wKBgGpkm1XtQGPIZz5DM15MHBmjePJin/Uh2a4YdVyo",
	"JTFvMhtL+NZSlsQ7NF2g+HfrT7d6Tob5Y9UN7Ezwxfwu7Jj/h0RVc2gGmyRUJrMV",
	"gVXRUK5yoTWv9eTq4iIfNNlajBmrj1SnyEClOnQjrDXklIMXYFfuhj1rNvILPnzJ",
	"uS0BAoGBAO2umWPJ9FlUZBrzYvVFr0E/7nHhaG/NLT3xkVDFQeywDbNaogJ/W02I",
	"L6XuKoPakun1aQx3bjGMtFBaqyTFMWBCg4S2olCRWGp5yULklS+cKR09mN1cjfb+",
	"6Th6jv0s3yYm5Ve6Jha0zTQQRWtDKZ5w/qxR0FJ65x+fkoEQMiEO",
	"-----END RSA PRIVATE KEY-----",
].join("\n") + "\n";

const imported = rsaImportPrivate(pem);
if (!imported.ok) throw new Error("rsaImportPrivate failed");
const signed = rsaSign(imported.value, "first call", "sha256");
const verified = signed.ok && rsaVerify(imported.value, "first call", signed.value, "sha256");
console.log(`first-call sign ${signed.ok} verify ${verified}`);
rsaFree(imported.value);
