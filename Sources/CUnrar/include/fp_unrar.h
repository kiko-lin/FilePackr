// Capa C mínima sobre la API DLL de unrar (RARLAB) para consumirla desde Swift sin exponer
// las estructuras empaquetadas (`#pragma pack(1)`) ni `wchar_t` de `dll.hpp`.
//
// FilePackr (GPL-3.0-or-later) se enlaza con unrar bajo la excepción de LICENSE-EXCEPTION.
//
// UnRAR source code may be used in any software to handle RAR archives without limitations
// free of charge, but cannot be used to develop RAR (WinRAR) compatible archiver and to
// re-create RAR compression algorithm, which is proprietary. Distribution of modified UnRAR
// source code in separate form or as a part of other software is permitted, provided that
// full text of this paragraph, starting from "UnRAR source code" words, is included in
// license, or in documentation if license is not available, and in source code comments of
// resulting package.

#ifndef FP_UNRAR_H
#define FP_UNRAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Códigos de resultado: los `ERAR_*` de unrar (0 = éxito, 10 = fin del archivo, …).
enum {
    FP_UNRAR_SUCCESS = 0,
    FP_UNRAR_END_ARCHIVE = 10,
    FP_UNRAR_NO_MEMORY = 11,
    FP_UNRAR_BAD_DATA = 12,
    FP_UNRAR_BAD_ARCHIVE = 13,
    FP_UNRAR_UNKNOWN_FORMAT = 14,
    FP_UNRAR_EOPEN = 15,
    FP_UNRAR_EREAD = 18,
    FP_UNRAR_UNKNOWN = 21,
    FP_UNRAR_MISSING_PASSWORD = 22,
    FP_UNRAR_BAD_PASSWORD = 24,
    FP_UNRAR_LARGE_DICT = 25,
};

typedef struct fp_unrar fp_unrar;

/// Recibe un trozo de datos en claro. Devolver distinto de 0 aborta la extracción.
typedef int (*fp_unrar_data_fn)(void *context, const unsigned char *bytes, size_t length);

typedef struct {
    /// Ruta dentro del archivo en UTF-8 (separador "/"). Válida hasta la siguiente llamada.
    const char *path;
    uint64_t packed_size;
    uint64_t unpacked_size;
    /// Segundos desde 1970 (0 si no hay fecha).
    int64_t mtime;
    int is_directory;
    int is_encrypted;
} fp_unrar_entry;

/// Abre `path` (primer volumen si es multivolumen). `for_extract` = 0 para solo listar.
/// `password` en UTF-8 o NULL. En fallo devuelve NULL y deja el código en `*result`.
/// `*headers_encrypted` se marca si las cabeceras van cifradas.
fp_unrar *fp_unrar_open(const char *path, int for_extract, const char *password,
                        int *result, int *headers_encrypted);

/// Lee la cabecera de la siguiente entrada.
int fp_unrar_next(fp_unrar *handle, fp_unrar_entry *entry);

/// Salta los datos de la entrada actual.
int fp_unrar_skip(fp_unrar *handle);

/// Descomprime la entrada actual emitiendo los datos por `fn` (nunca escribe a disco).
int fp_unrar_read(fp_unrar *handle, fp_unrar_data_fn fn, void *context);

/// El recorrido falló porque faltaba un volumen siguiente.
int fp_unrar_volume_missing(const fp_unrar *handle);

/// Se pidió contraseña durante la última operación.
int fp_unrar_password_requested(const fp_unrar *handle);

void fp_unrar_close(fp_unrar *handle);

#ifdef __cplusplus
}
#endif

#endif
