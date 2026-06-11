/* incitez CLI — thin I/O shell over the C FFI (dogfooding the boundary).
 * All citation logic lives in the Zig core behind include/incitez.h. */
#include <stdio.h>
#include <string.h>
#include "incitez.h"

#if defined(__APPLE__)
#define INCITEZ_OS "macos"
#elif defined(_WIN32)
#define INCITEZ_OS "windows"
#elif defined(__linux__)
#define INCITEZ_OS "linux"
#else
#define INCITEZ_OS "unknown-os"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define INCITEZ_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define INCITEZ_ARCH "x86_64"
#else
#define INCITEZ_ARCH "unknown-arch"
#endif

static void print_help(FILE* out) {
	fputs(
		"Usage: incitez [OPTIONS]\n"
		"\n"
		"Legal citation extraction engine (eyecite-compatible).\n"
		"\n"
		"Options:\n"
		"  -h, --help, /h   Show this help\n"
		"  --about          One-line description, version, and platform\n",
		out);
}

int main(int argc, char* argv[]) {
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--about") == 0) {
			printf("incitez %s — legal citation extraction engine (%s-%s)\n",
			       incitez_version(), INCITEZ_OS, INCITEZ_ARCH);
			return 0;
		}
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0 ||
		    strcmp(argv[i], "/h") == 0) {
			print_help(stdout);
			return 0;
		}
	}
	print_help(stderr);
	return 2;
}
