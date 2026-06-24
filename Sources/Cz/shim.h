// Acceso a la zlib del sistema. La cabecera `zlib.h` sí está en el SDK de macOS (a
// diferencia de la de libarchive/liblzma), así que la incluimos directamente y solo
// añadimos un par de ayudantes `static inline` para las dos macros que Swift no importa.
#ifndef CZ_SHIM_H
#define CZ_SHIM_H

#include <zlib.h>

// Inicializa un encoder DEFLATE **en crudo** (windowBits = -15, sin envoltura zlib/gzip),
// que es lo que necesitan el formato ZIP y el cuerpo de gzip. La macro `deflateInit2`
// (que fija versión y tamaño del stream) no es visible desde Swift; este wrapper sí.
static inline int cz_deflate_init_raw(z_stream *strm, int level) {
    return deflateInit2(strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
}

#endif
