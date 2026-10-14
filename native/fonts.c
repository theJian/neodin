#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <CoreText/CoreText.h>
char *nd_font_path(const char *name) {
    CFStringRef family = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!family) return NULL;
    CTFontRef font = CTFontCreateWithName(family, 16, NULL);
    if (!font) { CFRelease(family); return NULL; }
    CFStringRef actual_family = CTFontCopyFamilyName(font);
    CFStringRef actual_name = CTFontCopyPostScriptName(font);
    int matches = CFStringCompare(family, actual_family, kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
                  CFStringCompare(family, actual_name, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    CFRelease(family); CFRelease(actual_family); CFRelease(actual_name);
    if (!matches) { CFRelease(font); return NULL; }
    CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
    CFRelease(font);
    if (!url) return NULL;
    char path[4096];
    int ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path));
    CFRelease(url);
    return ok ? strdup(path) : NULL;
}
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
/* Windows exposes installed font files in this registry key. */
char *nd_font_path(const char *name) {
    wchar_t family[256];
    if (!MultiByteToWideChar(CP_UTF8, 0, name, -1, family, 256)) return NULL;
    HKEY key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", 0, KEY_READ, &key) != ERROR_SUCCESS) return NULL;
    wchar_t label[512], file[2048], path[4096];
    char *result = NULL;
    size_t length = wcslen(family);
    for (DWORD i = 0;; ++i) {
        DWORD label_size = 512, file_size = sizeof(file), type;
        LONG status = RegEnumValueW(key, i, label, &label_size, NULL, &type, (BYTE *)file, &file_size);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS || type != REG_SZ || !length || file_size < sizeof(wchar_t)) continue;
        file[2047] = 0;
        if (_wcsnicmp(label, family, length) || (label[length] != L' ' && label[length] != 0)) continue;
        if (wcsstr(file, L":") || file[0] == L'\\') {
            wcscpy_s(path, 4096, file);
        } else {
            UINT n = GetWindowsDirectoryW(path, 4096);
            if (!n || n >= 4000) continue;
            wcscat_s(path, 4096, L"\\Fonts\\"); wcscat_s(path, 4096, file);
        }
        int size = WideCharToMultiByte(CP_UTF8, 0, path, -1, NULL, 0, NULL, NULL);
        result = malloc(size);
        if (result) WideCharToMultiByte(CP_UTF8, 0, path, -1, result, size, NULL, NULL);
        break;
    }
    RegCloseKey(key);
    return result;
}
#else
#include <fontconfig/fontconfig.h>
char *nd_font_path(const char *name) {
    FcPattern *pattern = FcNameParse((const FcChar8 *)name);
    if (!pattern) return NULL;
    FcConfigSubstitute(NULL, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult status;
    FcPattern *font = FcFontMatch(NULL, pattern, &status);
    FcPatternDestroy(pattern);
    if (!font) return NULL;
    FcChar8 *path = NULL;
    char *result = NULL;
    if (FcPatternGetString(font, FC_FILE, 0, &path) == FcResultMatch) result = strdup((const char *)path);
    FcPatternDestroy(font);
    return result;
}
#endif
