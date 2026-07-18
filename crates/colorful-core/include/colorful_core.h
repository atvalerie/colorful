#ifndef COLORFUL_CORE_H
#define COLORFUL_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t colorful_core_abi_version(void);

/* Returned UTF-8 JSON strings must be released with colorful_string_free. */
char *colorful_engine_open(const char *database_path);
char *colorful_engine_dispatch(uint64_t handle, const char *command_json);
char *colorful_engine_snapshot(uint64_t handle);
bool colorful_engine_close(uint64_t handle);
char *colorful_tidal_map_tracks(const char *document_json);
void colorful_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
