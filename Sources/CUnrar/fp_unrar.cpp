// Implementación de `fp_unrar.h` sobre `dll.hpp` (ver la nota de licencia en la cabecera).

#include "rar.hpp"
#include "fp_unrar.h"

#include <string>

struct fp_unrar {
    HANDLE archive = nullptr;
    std::wstring password;
    bool has_password = false;
    bool password_requested = false;
    bool volume_missing = false;
    fp_unrar_data_fn data_fn = nullptr;
    void *data_context = nullptr;
    std::string path;
    std::string entry_path;
    std::wstring name_buffer = std::wstring(32768, L'\0');
};

// UTF-8 → UTF-32 (`wchar_t` en macOS). Secuencias inválidas → U+FFFD.
static std::wstring utf8_to_wide(const char *s) {
    std::wstring out;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        uint32_t c = *p;
        int extra = c < 0x80 ? 0 : (c >> 5) == 0x6 ? 1 : (c >> 4) == 0xE ? 2 : (c >> 3) == 0x1E ? 3 : -1;
        if (extra < 0) { out.push_back(0xFFFD); p++; continue; }
        c &= extra == 0 ? 0x7F : extra == 1 ? 0x1F : extra == 2 ? 0x0F : 0x07;
        p++;
        bool ok = true;
        for (int i = 0; i < extra; i++) {
            if ((*p & 0xC0) != 0x80) { ok = false; break; }
            c = (c << 6) | (*p++ & 0x3F);
        }
        out.push_back(ok ? (wchar_t)c : (wchar_t)0xFFFD);
    }
    return out;
}

static void wide_to_utf8(const wchar_t *s, std::string &out) {
    out.clear();
    for (; *s; s++) {
        uint32_t c = (uint32_t)*s;
        if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) c = 0xFFFD;
        if (c < 0x80) out.push_back((char)c);
        else if (c < 0x800) { out.push_back((char)(0xC0 | (c >> 6))); out.push_back((char)(0x80 | (c & 0x3F))); }
        else if (c < 0x10000) { out.push_back((char)(0xE0 | (c >> 12))); out.push_back((char)(0x80 | ((c >> 6) & 0x3F))); out.push_back((char)(0x80 | (c & 0x3F))); }
        else { out.push_back((char)(0xF0 | (c >> 18))); out.push_back((char)(0x80 | ((c >> 12) & 0x3F))); out.push_back((char)(0x80 | ((c >> 6) & 0x3F))); out.push_back((char)(0x80 | (c & 0x3F))); }
    }
}

static int CALLBACK callback(UINT msg, LPARAM user_data, LPARAM p1, LPARAM p2) {
    fp_unrar *h = (fp_unrar *)user_data;
    switch (msg) {
    case UCM_NEEDPASSWORDW: {
        h->password_requested = true;
        if (!h->has_password || p2 <= 0) return -1;
        wcsncpyz((wchar_t *)p1, h->password.c_str(), (size_t)p2);
        return 1;
    }
    case UCM_NEEDPASSWORD:
        return -1;   // solo se usa la variante ancha (la clave puede no ser ASCII)
    case UCM_CHANGEVOLUMEW:
    case UCM_CHANGEVOLUME:
        if (p2 == RAR_VOL_ASK) { h->volume_missing = true; return -1; }
        return 1;
    case UCM_PROCESSDATA:
        if (h->data_fn && h->data_fn(h->data_context, (const unsigned char *)p1, (size_t)p2) != 0) return -1;
        return 1;
    case UCM_LARGEDICT:
        return 0;   // no aceptar diccionarios por encima del máximo por defecto (memoria)
    default:
        return 0;
    }
}

fp_unrar *fp_unrar_open(const char *path, int for_extract, const char *password,
                        int *result, int *headers_encrypted) {
    fp_unrar *h = new fp_unrar();
    h->path = path;
    if (password) { h->password = utf8_to_wide(password); h->has_password = true; }

    RAROpenArchiveDataEx data{};
    data.ArcName = (char *)h->path.c_str();
    data.OpenMode = for_extract ? RAR_OM_EXTRACT : RAR_OM_LIST;
    data.Callback = callback;
    data.UserData = (LPARAM)h;
    h->archive = RAROpenArchiveEx(&data);
    if (headers_encrypted) *headers_encrypted = (data.Flags & ROADF_ENCHEADERS) != 0;
    if (!h->archive) {
        *result = data.OpenResult != 0 ? (int)data.OpenResult : FP_UNRAR_EOPEN;
        if (headers_encrypted && (*result == FP_UNRAR_MISSING_PASSWORD || *result == FP_UNRAR_BAD_PASSWORD))
            *headers_encrypted = 1;
        delete h;
        return nullptr;
    }
    *result = FP_UNRAR_SUCCESS;
    return h;
}

int fp_unrar_next(fp_unrar *h, fp_unrar_entry *entry) {
    RARHeaderDataEx header{};
    header.FileNameEx = &h->name_buffer[0];
    header.FileNameExSize = (unsigned int)h->name_buffer.size();
    h->password_requested = false;
    int r = RARReadHeaderEx(h->archive, &header);
    if (r != ERAR_SUCCESS) return r;

    wide_to_utf8(header.FileNameEx[0] ? header.FileNameEx : header.FileNameW, h->entry_path);
    entry->path = h->entry_path.c_str();
    entry->packed_size = ((uint64_t)header.PackSizeHigh << 32) | header.PackSize;
    entry->unpacked_size = ((uint64_t)header.UnpSizeHigh << 32) | header.UnpSize;
    uint64_t filetime = ((uint64_t)header.MtimeHigh << 32) | header.MtimeLow;   // 100 ns desde 1601
    entry->mtime = filetime == 0 ? 0 : (int64_t)(filetime / 10000000ULL) - 11644473600LL;
    entry->is_directory = (header.Flags & RHDF_DIRECTORY) != 0;
    entry->is_encrypted = (header.Flags & RHDF_ENCRYPTED) != 0;
    return ERAR_SUCCESS;
}

int fp_unrar_skip(fp_unrar *h) {
    h->data_fn = nullptr;
    return RARProcessFileW(h->archive, RAR_SKIP, nullptr, nullptr);
}

int fp_unrar_read(fp_unrar *h, fp_unrar_data_fn fn, void *context) {
    h->data_fn = fn;
    h->data_context = context;
    h->password_requested = false;
    // RAR_TEST descomprime y verifica sin crear ficheros: los datos solo salen por el callback.
    int r = RARProcessFileW(h->archive, RAR_TEST, nullptr, nullptr);
    h->data_fn = nullptr;
    h->data_context = nullptr;
    return r;
}

int fp_unrar_volume_missing(const fp_unrar *h) { return h->volume_missing; }

int fp_unrar_password_requested(const fp_unrar *h) { return h->password_requested; }

void fp_unrar_close(fp_unrar *h) {
    if (!h) return;
    if (h->archive) RARCloseArchive(h->archive);
    delete h;
}
