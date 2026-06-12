#ifndef INCITEZ_H
#define INCITEZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the library version as a static null-terminated string. */
const char* incitez_version(void);

/* One extracted citation. All strings are NUL-terminated UTF-8 owned by the
 * result (valid until incitez_result_free); nullable fields are NULL when
 * absent. Spans are byte offsets into the input text. */
typedef struct {
    const char* kind; /* "FullCaseCitation", "ShortCaseCitation", ... */
    uint32_t span_start;
    uint32_t span_end;
    uint32_t full_span_start;
    uint32_t full_span_end;
    const char* volume;
    const char* reporter;
    const char* page;
    const char* corrected_reporter;
    const char* pin_cite;
    const char* court; /* resolved courts-db id, e.g. "scotus" */
    int32_t year;      /* -1 when absent */
    const char* parenthetical;
    const char* extra;
    const char* plaintiff;
    const char* defendant;
    const char* antecedent_guess;
    int32_t resolution; /* index of the anchoring citation; -1 unresolved */
} incitez_citation;

/* Opaque result handle; owns all citation memory (arena). */
typedef struct incitez_result incitez_result;

/* Extract citations from text (UTF-8, len bytes). engine: NULL or "vm" for
 * the native engine, "pcre2" for the alternate path. NULL on failure. */
incitez_result* incitez_extract(const char* text, size_t len, const char* engine);

size_t incitez_result_count(const incitez_result* result);

/* Borrowed pointer into the result; NULL when idx is out of range. */
const incitez_citation* incitez_result_get(const incitez_result* result, size_t idx);

void incitez_result_free(incitez_result* result);

/* Convenience: extract + resolve + serialize to a NUL-terminated JSON string
 * (the `--json` schema). Returns NULL on failure. Caller frees the returned
 * string with incitez_string_free. The same serializer backs the WASM
 * export, so output is byte-identical across CLI and browser. */
char* incitez_extract_json(const char* text, size_t len, const char* engine);

void incitez_string_free(char* s);

#ifdef __cplusplus
}
#endif

#endif /* INCITEZ_H */
