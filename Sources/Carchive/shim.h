// Declaraciones mínimas de la libarchive del sistema (Apple no incluye sus
// cabeceras en el SDK, pero sí el stub enlazable libarchive.tbd → -larchive).
// Solo declaramos las funciones que usamos; la API 3.x es estable desde hace años.
#ifndef CARCHIVE_SHIM_H
#define CARCHIVE_SHIM_H

#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

// --- Lectura ---
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_memory(struct archive *, const void *buff, size_t size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int64_t archive_read_data(struct archive *, void *buff, size_t len);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_free(struct archive *);

// --- Escritura ---
struct archive *archive_write_new(void);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_iso9660(struct archive *);
int archive_write_set_format_xar(struct archive *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_header(struct archive *, struct archive_entry *);
int64_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// --- Entrada (metadatos) ---
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
unsigned int archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_mtime(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, int);
void archive_entry_set_mtime(struct archive_entry *, int64_t, long);

// --- Errores ---
const char *archive_error_string(struct archive *);

#endif
