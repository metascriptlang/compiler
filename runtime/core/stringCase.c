/*
 * String trim and case conversion with the ECMAScript result: WhiteSpace and LineTerminator for trim,
 * the full Unicode default case mapping (SpecialCasing included) and Final_Sigma for the case
 * functions. A string known to be ASCII takes a byte loop; the rest decodes WTF-8 and reads the
 * tables of stringCaseTables.h by binary search. An ill-formed byte and an encoded surrogate map to themselves.
 */

#include "runtime/core/string.h"
#include "runtime/core/stringCaseTables.h"

#define MS_NO_CP 0xFFFFFFFFu

static int64_t msDecodeCp(const uint8_t* p, int64_t n, uint32_t* cp) {
	const uint8_t b = p[0];
	*cp = MS_NO_CP;
	if (b < 0x80) { *cp = b; return 1; }
	if (b >= 0xC2 && b <= 0xDF && n >= 2 && (p[1] & 0xC0) == 0x80) {
		*cp = ((uint32_t)(b & 0x1F) << 6) | (p[1] & 0x3F);
		return 2;
	}
	if (b >= 0xE0 && b <= 0xEF && n >= 3 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
		*cp = ((uint32_t)(b & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
		return 3;
	}
	if (b >= 0xF0 && b <= 0xF4 && n >= 4 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80) {
		*cp = ((uint32_t)(b & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12) | ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
		return 4;
	}
	return 1;
}

static int64_t msEncodeCp(uint32_t cp, uint8_t* out) {
	if (cp < 0x80) { out[0] = (uint8_t)cp; return 1; }
	if (cp < 0x800) { out[0] = (uint8_t)(0xC0 | (cp >> 6)); out[1] = (uint8_t)(0x80 | (cp & 0x3F)); return 2; }
	if (cp < 0x10000) {
		out[0] = (uint8_t)(0xE0 | (cp >> 12)); out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); out[2] = (uint8_t)(0x80 | (cp & 0x3F));
		return 3;
	}
	out[0] = (uint8_t)(0xF0 | (cp >> 18)); out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
	out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); out[3] = (uint8_t)(0x80 | (cp & 0x3F));
	return 4;
}

/* The code point that ends at *end, and *end moved to where it starts. */
static uint32_t msPrevCp(const uint8_t* s, int64_t* end) {
	int64_t k = *end - 1;
	for (int c = 0; k > 0 && c < 3 && (s[k] & 0xC0) == 0x80; c++) k--;
	uint32_t cp;
	if (k + msDecodeCp(s + k, *end - k, &cp) != *end) {
		k = *end - 1;
		cp = MS_NO_CP;
	}
	*end = k;
	return cp;
}

#define MS_COUNT(t) (sizeof(t) / sizeof((t)[0]))

static bool msInSpans(const msCaseSpan* t, size_t n, uint32_t cp) {
	size_t lo = 0, hi = n;
	while (lo < hi) {
		const size_t mid = lo + (hi - lo) / 2;
		if (cp < t[mid].lo) hi = mid;
		else if (cp > t[mid].hi) lo = mid + 1;
		else return true;
	}
	return false;
}

static bool msFindRun(const msCaseRun* t, size_t n, uint32_t cp, uint32_t* out) {
	size_t lo = 0, hi = n;
	while (lo < hi) {
		const size_t mid = lo + (hi - lo) / 2;
		if (cp < t[mid].lo) hi = mid;
		else if (cp > t[mid].hi) lo = mid + 1;
		else {
			if ((cp - t[mid].lo) % (uint32_t)t[mid].stride != 0) return false;
			*out = (uint32_t)((int32_t)cp + t[mid].delta);
			return true;
		}
	}
	return false;
}

static const msCaseFull* msFindFull(const msCaseFull* t, size_t n, uint32_t cp) {
	size_t lo = 0, hi = n;
	while (lo < hi) {
		const size_t mid = lo + (hi - lo) / 2;
		if (cp < t[mid].cp) hi = mid;
		else if (cp > t[mid].cp) lo = mid + 1;
		else return &t[mid];
	}
	return NULL;
}

/* A sigma at [at, after) is final when a cased letter precedes it and none follows, case-ignorable code points skipped. */
static bool msFinalSigma(const uint8_t* s, int64_t at, int64_t after, int64_t n) {
	int64_t j = at;
	uint32_t cp;
	for (;;) {
		if (j == 0) return false;
		cp = msPrevCp(s, &j);
		if (!msInSpans(msCaseIgnorableSpans, MS_COUNT(msCaseIgnorableSpans), cp)) break;
	}
	if (!msInSpans(msCasedSpans, MS_COUNT(msCasedSpans), cp)) return false;
	j = after;
	while (j < n) {
		const int64_t w = msDecodeCp(s + j, n - j, &cp);
		if (!msInSpans(msCaseIgnorableSpans, MS_COUNT(msCaseIgnorableSpans), cp)) return !msInSpans(msCasedSpans, MS_COUNT(msCasedSpans), cp);
		j += w;
	}
	return true;
}

static int64_t msCpWidth(uint32_t cp) {
	return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
}

/* The converted bytes, written to dst when it is not NULL; the return value is their count. */
static int64_t msConvertCase(const uint8_t* s, int64_t n, uint8_t* dst, bool upper) {
	const uint8_t asciiLo = upper ? 'a' : 'A';
	int64_t i = 0, o = 0;
	while (i < n) {
		const uint8_t b = s[i];
		if (b < 0x80) {
			if (dst != NULL) dst[o] = (uint8_t)(b ^ (((uint8_t)(b - asciiLo) < 26) << 5));
			i++;
			o++;
			continue;
		}
		uint32_t cp;
		const int64_t w = msDecodeCp(s + i, n - i, &cp);
		uint32_t one = cp;
		const msCaseFull* full = NULL;
		if (cp != MS_NO_CP) {
			if (!upper && cp == 0x3A3) one = msFinalSigma(s, i, i + w, n) ? 0x3C2 : 0x3C3;
			else {
				full = upper ? msFindFull(msUpperFull, MS_COUNT(msUpperFull), cp) : msFindFull(msLowerFull, MS_COUNT(msLowerFull), cp);
				if (full == NULL) {
					if (upper) msFindRun(msUpperRuns, MS_COUNT(msUpperRuns), cp, &one);
					else msFindRun(msLowerRuns, MS_COUNT(msLowerRuns), cp, &one);
				}
			}
		}
		if (full != NULL) {
			for (int k = 0; k < 3 && full->out[k] != 0; k++) {
				if (dst != NULL) msEncodeCp(full->out[k], dst + o);
				o += msCpWidth(full->out[k]);
			}
		} else if (cp == MS_NO_CP || one == cp) {
			if (dst != NULL) for (int64_t k = 0; k < w; k++) dst[o + k] = s[i + k];
			o += w;
		} else {
			if (dst != NULL) msEncodeCp(one, dst + o);
			o += msCpWidth(one);
		}
		i += w;
	}
	return o;
}

static msString msCaseOf(msString s, bool upper) {
	if (s.len == 0) return msStringNewUninit(0);
	const uint8_t* src = (const uint8_t*)s.p->data;
	if (msStringIsAscii(s)) {
		msString r = msStringNewUninit(s.len);
		uint8_t* dst = (uint8_t*)r.p->data;
		const uint8_t lo = upper ? 'a' : 'A';
		for (int64_t i = 0; i < s.len; i++) {
			const uint8_t c = src[i];
			dst[i] = (uint8_t)(c ^ (((uint8_t)(c - lo) < 26) << 5));
		}
		msStringMarkAscii(r);
		return r;
	}
	msString r = msStringNewUninit(msConvertCase(src, s.len, NULL, upper));
	if (r.len > 0) msConvertCase(src, s.len, (uint8_t*)r.p->data, upper);
	return r;
}

msString msStringToUpperCase(msString s) { return msCaseOf(s, true); }
msString msStringToLowerCase(msString s) { return msCaseOf(s, false); }

/* ECMAScript WhiteSpace and LineTerminator. */
static bool msIsTrimmed(uint32_t cp) {
	return (cp >= 9 && cp <= 13) || cp == 0x20 || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
		cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000 || cp == 0xFEFF;
}

static msString msTrimOf(msString s, bool lead, bool trail) {
	if (s.len == 0) return msStringNewUninit(0);
	const uint8_t* p = (const uint8_t*)s.p->data;
	int64_t a = 0, b = s.len;
	uint32_t cp;
	if (lead) {
		for (int64_t w; a < b && (w = msDecodeCp(p + a, b - a, &cp)) > 0 && msIsTrimmed(cp);) a += w;
	}
	if (trail) {
		for (int64_t e = b; b > a;) {
			cp = msPrevCp(p, &e);
			if (e < a || !msIsTrimmed(cp)) break;
			b = e;
		}
	}
	msString r = msStringNewUninit(b - a);
	if (r.len > 0) memcpy(r.p->data, p + a, (size_t)(b - a));
	if (msStringKnownAscii(s)) msStringMarkAscii(r);
	return r;
}

msString msStringTrim(msString s) { return msTrimOf(s, true, true); }
msString msStringTrimStart(msString s) { return msTrimOf(s, true, false); }
msString msStringTrimEnd(msString s) { return msTrimOf(s, false, true); }
