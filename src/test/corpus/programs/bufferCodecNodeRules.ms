// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: 27f1,27f1;,;,;d8ff,d8ff;1be4529d7608,1be4529d7608;dba7e6,dba7e6;275afe26ce8b,275afe26ce8b;,;e71ece,e71ece;dedc,dedc;,;,;68e1,68e1;,;b8980e,b8980e;,;51a0ff85572a,51a0ff85572a;cddfc362cb0d67,cddfc362cb0d67;facfff5aac8a,facfff5aac8a;43,43;a75f,a75f;,;fd9e7d7e,fd9e7d7e;4d133e73764b,4d133e73764b;e31948,e31948;85743f2d724285c3eb,85743f2d724285c3eb;,;6d1b,6d1b;9255f9ba75f08d900b,9255f9ba75f08d900b;16,16;293c,293c;4b,4b;47e16ef9f008,47e16ef9f008;f096bac244a6,f096bac244a6;07e33e93b2be,07e33e93b2be;e5a2,e5a2;,;f94fb34b0a,f94fb34b0a;,;665209,665209;9138,9138;60,60;4644359a17,4644359a17;c94ff9,c94ff9;e5858bbd96abb9b7f9,e5858bbd96abb9b7f9;fb6f32,fb6f32;35334540,35334540;4373a661cfa6,4373a661cfa6;7f49d8d5db,7f49d8d5db;aee6,aee6;,;21961c97f707,21961c97f707;a0,a0;63bc0d8f5fda9fce6e,63bc0d8f5fda9fce6e;f9f10722afa8,f9f10722afa8;,;fdde,fdde;ff2129,ff2129;,;33945e3e285f,33945e3e285f;
// @stdout: bc78;e8;;ec7a;;d60a;bf;;cecabdff;cebe;0d802057;;2a;;;;e7;4ce8a1;6e;;9a1a17;a22d8a;e8be12;;;59c4fa;;;d0;;
// @stdout: 0:0000000000000000;3:00000000ea958200;5:00000038bb4b3239;0:0000000000000000;2:000000000000289a;0:0000000000000000;0:0000000000000000;4:000000ebcf9cc600;3:0000000000bd54be;-9:0000000000000000;3:00000000005c3bc8;-9:0000000000000000;0:0000000000000000;1:00000000000000b9;1:0000009100000000;2:000000bf62000000;3:00000000005ff6d9;-9:0000000000000000;-9:0000000000000000;0:0000000000000000;-9:0000000000000000;4:0000fd9e7d7e0000;-9:0000000000000000;4:00000000f2fd3a5c;-9:0000000000000000;-9:0000000000000000;1:000000000000001f;1:0000000000c40000;4:000000005d2d24af;-9:0000000000000000;-9:0000000000000000;2:00c38f0000000000;1:0000000000000300;5:000000cdb3cb8b14;0:0000000000000000;0:0000000000000000;-9:0000000000000000;2:0000000000004b5a;1:00000000000000a0;1:0000000000000078;
// @stdout: -9:000000000000;2:adfa00000000;0:000000000000;0:000000000000;-9:000000000000;0:000000000000;0:000000000000;0:000000000000;2:00000000c2bb;0:000000000000;0:000000000000;-9:000000000000;-9:000000000000;-9:000000000000;0:000000000000;3:0094d4530000;0:000000000000;0:000000000000;4:b3eaabc10000;1:0000000000a2;1:0000000000ca;0:000000000000;-9:000000000000;0:000000000000;-9:000000000000;-9:000000000000;-9:000000000000;0:000000000000;1:00000000002a;0:000000000000;
// @stdout: ff|+/9/gGhp|00fbff7f|_3-AaGk-P8g|||||||3f|+/8=|f4BoaT4/yA==||APv/f4BoaT4/||APv_f4Bo|AA|APv_f4BoaT4|127.128.104.105.62.63.200.|APv_fw|0.123.127.127.0.104.105.|||yA|gGhp|/3+AaA==||AA|3e3f||00||aT4=|||00|||APv_f4BoaT4_|
function codes(s: string): string { let o = ""; for (let i = 0; i < s.length; i++) o += s.charCodeAt(i).toString() + "."; return o; }
const cases: string[] = ["*J_H ", "", "I", "2P-", "G-RSnXYIa", "2.6f mr", "J1r+J\ns6L.I", "", "5x\n7Ob=y/5j", "3 tw=TdXAvo-yy", "z", "", "aOG", "T", "uJ*g\nO.n", "r", "Ua\nD _hVcqY", "zd/D Yss\nNZ9", "-s__ WqyK", "Q7=8sQNRY b", "p1-\n", "1=C=T8Pp9_-jMD", "_Z59fh =yJ2m", "T\nR M+c3*ZLC", "4xlId", "hXQ /LXJChcPr*", "=e=XnaWC-Yf_3y", "b\nRs=gHw", "klX5u\nnXwjZAL", "Fm", "KTx.", "S2", "R- Fu*-fAIL", "8J a6wk Sm", "B+M+k7 K-", "5*aL", "h=", " \n+U+zSwq", "", "*ZlIJ", "  kTi", "Y** G*", "RkQ1mhe", "yU/5", "5YWLvZ*ar.ubf5", "-28.y.", "NTN.FQE", "Q3OmYc-m  ", "f0nY1dv", "ruZ", "", "IZYcl/cH=-SH", "oK", "Y7w\nNj1_an*85u", "-f*EHI\nq-o ", "", "_d7**==m=p.", "_y Ep", "_ ", "M5ReP ihf"];
const hexes: string[] = ["Bc78zxagd", "e8", "4 =dg 5=c", "EC7A", "bx285 dA2", "D60aE=zgzcz", "bf4zg", "", "cECabdfF", "cEBECz95DF", "0d8020573", "z", "2a", "f 28", "1", "zafDx4d0234", "e7F", "4CE8A10", "6e5", " 1a", "9A1a17E=aAb", "A22d8Aa=ba", "e8Be12 23", "gF3aBd5db7B", "c", "59c4fA7", "", "4x5a", "d0x81 a8 b", "3g=C7E"];
const wtext: string[] = ["z", "  6pWCUAh", "OLtLMjlq-F", "=\nj.0 yk", "KJp6RH-7cr", "\n- fwd p2", "", "6 8-cx*t", "vVS-", " Vg", "XDv.I", "-r", " Z=FUPYEp6", "uUGyvV", "  kTi", "v2J", "X\n*_bZM.", "KNty_Dm", "", " Z", "6\nT8K\nQ aC 3*3", "_Z59fh =yJ2m", "A.", "8v06XPtg", "f*_", "-ooq", "H-r", "xB3l", "XS0kr0A zj=e", "lLT3z", "XDv.I", "\nw48", "A5", "\nzbPLixSx", " O", "Vd=E", "ma8B 5S ", ".S1ruarG /i\n", "oK", "eEz"];
const woff: number[] = [3, 4, 3, 0, 6, 4, 7, 3, 5, 8, 5, 8, 7, 7, 3, 3, 5, 9, 9, 6, 9, 2, 9, 4, 9, 9, 7, 5, 4, -1, 9, 1, 6, 3, 1, 1, 8, 6, 7, 7];
const wlen: number[] = [6, 3, 9, 0, 4, 0, 7, 4, 7, 8, 6, 2, 9, -1, 1, 8, 6, 0, 0, 9, 5, 5, 5, 9, 3, 8, 5, 1, 7, 0, 0, 4, 6, 8, 7, 0, 7, 4, 1, 2];
const htext: string[] = ["4D8F", "ADFa", " 5=4b3=Dg5", "", "4D8F", " e6b30g2", "9=", "9=", "C2bbB43db", "z=83Ca", "F1g", "", "Ce6c", "048x= e39", " 5=4b3=Dg5", "94D453", "2zdeb5AbBca", "", "B3eAABc1f", "A22d8Aa=ba", "CAC5", " e6b30g2", "FB625", "=80", "048x= e39", "dCE", "0zadB9D", "", "2AD=e5E0b23", "gF3aBd5db7B"];
const hoff: number[] = [-1, 0, 4, 5, 7, 5, 5, 0, 4, 2, 5, 6, 6, 6, 0, 1, 2, 5, 0, 5, 5, 3, 6, 1, 7, -1, 6, 5, 5, 0];
const hlen: number[] = [5, -1, 2, 4, 4, 0, 3, 2, 6, 6, 0, 0, 5, 3, 2, 7, -1, 4, 7, 1, 7, 4, 3, 1, -1, 3, 4, -1, 2, 2];
const rs: number[] = [2, 1, 0, 2, 7, 2, 6, 8, 9, 6, 8, 1, 3, 4, -2, 8, -2, 0, -1, 3, 0, -1, 5, 6, 9, 4, 2, 5, 0, 7, 1, -2, 6, 6, 5, 5, -2, 8, 6, -2];
const re: number[] = [3, 7, 4, -1, 0, 2, 4, 5, 8, 3, 9, 3, 10, 2, 9, 2, 6, 1, 8, -1, 4, 7, 2, 6, -2, 7, 6, 5, 1, 9, 1, 1, 1, 8, 3, 3, 1, 1, 5, 9];
const renc: string[] = ["HEX", "base64", "HEX", "base64url", "hex", "Base64", "base64url", "base64url", "HEX", "base64url", "hex", "base64", "base64", "base64url", "Base64", "base64url", "base64url", "base64url", "base64url", "latin1", "base64url", "ascii", "base64url", "Base64", "base64url", "Base64", "base64", "base64url", "base64url", "hex", "base64", "HEX", "base64", "Base64", "Base64", "HEX", "HEX", "ascii", "base64", "base64url"];

let out = "";
for (const s of cases) out += Buffer.fromString(s, "base64").toHex() + "," + Buffer.fromString(s, "base64url").toHex() + ";";
console.log(out);
out = "";
for (const s of hexes) out += Buffer.fromString(s, "hex").toHex() + ";";
console.log(out);
out = "";
for (let i = 0; i < wtext.length; i++) { const b = Buffer.alloc(8); const n = woff[i] >= 0 && woff[i] < 8 ? b.write(wtext[i], woff[i], wlen[i] < 0 || wlen[i] > 8 ? 8 : wlen[i], "base64") : -9; out += n.toString() + ":" + b.toHex() + ";"; }
console.log(out);
out = "";
for (let i = 0; i < htext.length; i++) { const b = Buffer.alloc(6); const n = hoff[i] >= 0 && hoff[i] < 6 ? b.write(htext[i], hoff[i], hlen[i] < 0 || hlen[i] > 6 ? 6 : hlen[i], "hex") : -9; out += n.toString() + ":" + b.toHex() + ";"; }
console.log(out);
const src = Buffer.fromArray([0, 251, 255, 127, 128, 104, 105, 62, 63, 200]);
out = "";
for (let i = 0; i < rs.length; i++) { const a = rs[i] < 0 ? 0 : rs[i]; const z = re[i] < 0 ? 10 : re[i]; const r = src.toStringEncoded(renc[i], a, z); out += (renc[i] == "ascii" || renc[i] == "latin1" ? codes(r) : r) + "|"; }
console.log(out);
