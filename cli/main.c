/* incitez CLI — thin I/O shell over the C FFI (dogfooding the boundary).
 * All citation logic lives in the Zig core behind include/incitez.h. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
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
		"Usage: incitez extract <file> [--json] [--engine vm|pcre2]\n"
		"       incitez [--help | --about]\n"
		"\n"
		"Legal citation extraction engine (eyecite-compatible).\n"
		"\n"
		"Arguments:\n"
		"  <file>             Input text file; \"-\" or \"@stdin\" reads stdin\n"
		"\n"
		"Options:\n"
		"  --json             JSON output (one array of citation objects)\n"
		"  --engine ENGINE    Matching engine: vm (default) or pcre2;\n"
		"                     INCITEZ_ENGINE env var sets the default\n"
		"  -h, --help, /h     Show this help\n"
		"  --about            One-line description, version, and platform\n",
		out);
}

static char* read_all(FILE* f, size_t* out_len) {
	size_t cap = 1 << 16, len = 0;
	char* buf = malloc(cap);
	if (!buf) return NULL;
	size_t n;
	while ((n = fread(buf + len, 1, cap - len, f)) > 0) {
		len += n;
		if (len == cap) {
			cap *= 2;
			char* nb = realloc(buf, cap);
			if (!nb) {
				free(buf);
				return NULL;
			}
			buf = nb;
		}
	}
	*out_len = len;
	return buf;
}

static void json_string(FILE* out, const char* s) {
	if (!s) {
		fputs("null", out);
		return;
	}
	fputc('"', out);
	for (const unsigned char* p = (const unsigned char*)s; *p; p++) {
		switch (*p) {
			case '"': fputs("\\\"", out); break;
			case '\\': fputs("\\\\", out); break;
			case '\n': fputs("\\n", out); break;
			case '\r': fputs("\\r", out); break;
			case '\t': fputs("\\t", out); break;
			default:
				if (*p < 0x20) {
					fprintf(out, "\\u%04x", *p);
				} else {
					fputc(*p, out);
				}
		}
	}
	fputc('"', out);
}

static void json_field(FILE* out, const char* name, const char* value, int* first) {
	if (!*first) fputs(", ", out);
	*first = 0;
	fprintf(out, "\"%s\": ", name);
	json_string(out, value);
}

static int cmd_extract(const char* path, int json, const char* engine) {
	FILE* in = stdin;
	if (strcmp(path, "-") != 0 && strcmp(path, "@stdin") != 0) {
		in = fopen(path, "rb");
		if (!in) {
			fprintf(stderr, "incitez: cannot open '%s': %s\n", path, strerror(errno));
			return 1;
		}
	}
	size_t len = 0;
	char* text = read_all(in, &len);
	if (in != stdin) fclose(in);
	if (!text) {
		fputs("incitez: out of memory reading input\n", stderr);
		return 1;
	}

	incitez_result* result = incitez_extract(text, len, engine);
	if (!result) {
		fprintf(stderr, "incitez: extraction failed (unknown engine '%s'?)\n",
		        engine ? engine : "vm");
		free(text);
		return 1;
	}

	size_t count = incitez_result_count(result);
	if (json) {
		fputs("[", stdout);
		for (size_t i = 0; i < count; i++) {
			const incitez_citation* c = incitez_result_get(result, i);
			if (i) fputs(",", stdout);
			fputs("\n {", stdout);
			int first = 1;
			json_field(stdout, "kind", c->kind, &first);
			fprintf(stdout, ", \"span\": [%u, %u], \"full_span\": [%u, %u]",
			        c->span_start, c->span_end, c->full_span_start, c->full_span_end);
			json_field(stdout, "volume", c->volume, &first);
			json_field(stdout, "reporter", c->reporter, &first);
			json_field(stdout, "page", c->page, &first);
			json_field(stdout, "corrected_reporter", c->corrected_reporter, &first);
			json_field(stdout, "pin_cite", c->pin_cite, &first);
			json_field(stdout, "court", c->court, &first);
			if (c->year >= 0) {
				fprintf(stdout, ", \"year\": %d", c->year);
			} else {
				fputs(", \"year\": null", stdout);
			}
			json_field(stdout, "parenthetical", c->parenthetical, &first);
			json_field(stdout, "extra", c->extra, &first);
			json_field(stdout, "plaintiff", c->plaintiff, &first);
			json_field(stdout, "defendant", c->defendant, &first);
			json_field(stdout, "antecedent_guess", c->antecedent_guess, &first);
			if (c->resolution >= 0) {
				fprintf(stdout, ", \"resolution\": %d", c->resolution);
			} else {
				fputs(", \"resolution\": null", stdout);
			}
			fputs("}", stdout);
		}
		fputs("\n]\n", stdout);
	} else {
		for (size_t i = 0; i < count; i++) {
			const incitez_citation* c = incitez_result_get(result, i);
			fprintf(stdout, "%zu\t%s\t[%u,%u)\t%.*s\n", i, c->kind, c->span_start,
			        c->span_end, (int)(c->span_end - c->span_start), text + c->span_start);
		}
	}
	fprintf(stderr, "%zu citation%s\n", count, count == 1 ? "" : "s");

	incitez_result_free(result);
	free(text);
	return 0;
}

int main(int argc, char* argv[]) {
	const char* engine = getenv("INCITEZ_ENGINE");
	const char* path = NULL;
	int json = 0;
	int extract = 0;

	for (int i = 1; i < argc; i++) {
		const char* a = argv[i];
		if (strcmp(a, "--about") == 0) {
			printf("incitez %s — legal citation extraction engine (%s-%s)\n",
			       incitez_version(), INCITEZ_OS, INCITEZ_ARCH);
			return 0;
		}
		if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0 || strcmp(a, "/h") == 0) {
			print_help(stdout);
			return 0;
		}
		if (strcmp(a, "--json") == 0 || strcmp(a, "/json") == 0) {
			json = 1;
		} else if (strcmp(a, "--engine") == 0 && i + 1 < argc) {
			engine = argv[++i];
		} else if (strcmp(a, "extract") == 0 && !extract) {
			extract = 1;
		} else if (extract && !path) {
			path = a;
		} else {
			fprintf(stderr, "incitez: unexpected argument '%s'\n", a);
			print_help(stderr);
			return 2;
		}
	}

	if (extract && path) return cmd_extract(path, json, engine);

	print_help(stderr);
	return 2;
}
