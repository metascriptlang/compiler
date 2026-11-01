/* The one OS CSPRNG of the crypto runtime. Every module that needs random bytes includes this:
 * ms_random_fill fills `len` bytes and returns 0, or returns -1 when the OS source failed.
 * len == 0 succeeds without calling the OS. */

#ifndef MS_CRYPTO_RANDOM_FILL_H
#define MS_CRYPTO_RANDOM_FILL_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#if defined(_WIN32)

#include <winsock2.h>
#include <windows.h>
#include <bcrypt.h>

static int ms_random_fill(uint8_t *buf, size_t len) {
	const size_t chunk = (size_t)1 << 30; /* BCryptGenRandom takes a 32-bit ULONG */
	while (len > 0) {
		size_t n = len < chunk ? len : chunk;
		if (BCryptGenRandom(NULL, buf, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return -1;
		buf += n;
		len -= n;
	}
	return 0;
}

#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)

#include <stdlib.h>

static int ms_random_fill(uint8_t *buf, size_t len) {
	if (len > 0) arc4random_buf(buf, len);
	return 0;
}

#elif defined(__wasi__)

#include <unistd.h>

static int ms_random_fill(uint8_t *buf, size_t len) {
	while (len > 0) {
		size_t n = len < 256 ? len : 256; /* getentropy takes at most 256 bytes */
		if (getentropy(buf, n) != 0) return -1;
		buf += n;
		len -= n;
	}
	return 0;
}

#elif defined(__linux__)

#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>

static int ms_random_fill(uint8_t *buf, size_t len) {
	size_t done = 0;
	while (done < len) {
		long got = syscall(SYS_getrandom, buf + done, len - done, 0);
		if (got > 0) {
			done += (size_t)got;
		} else if (got == 0 || (errno != EINTR && errno != EAGAIN)) {
			return -1;
		}
	}
	return 0;
}

#else

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static int ms_random_fill(uint8_t *buf, size_t len) {
	if (len == 0) return 0;
	int fd = open("/dev/urandom", O_RDONLY);
	if (fd < 0) return -1;
	struct stat st;
	int ok = fstat(fd, &st) == 0 && S_ISCHR(st.st_mode);
	size_t done = 0;
	while (ok && done < len) {
		ssize_t got = read(fd, buf + done, len - done);
		if (got > 0) done += (size_t)got;
		else if (got == 0 || errno != EINTR) ok = 0;
	}
	close(fd);
	return ok ? 0 : -1;
}

#endif

#endif /* MS_CRYPTO_RANDOM_FILL_H */
