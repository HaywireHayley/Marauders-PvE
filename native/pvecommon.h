/*
 * pvecommon.h: the few helpers the shipped native DLLs (pvepatch, pvenet, pvenative) share. Header-only, every
 * function static: each DLL is one translation unit, and nothing here is exported.
 */
#ifndef PVECOMMON_H
#define PVECOMMON_H

#include <windows.h>
#include <string.h>

#define PVE_COUNT(a) (sizeof(a) / sizeof((a)[0]))

/* 1 if [p, p+n) lies in one committed, readable region (a single VirtualQuery: never crosses a region boundary). */
static __attribute__((unused)) int pve_readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!VirtualQuery(p, &mbi, sizeof mbi) || mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
          PAGE_EXECUTE_WRITECOPY))) return 0;
    return (const char *)p + n <= (const char *)mbi.BaseAddress + mbi.RegionSize;
}

/* The project folder with a trailing backslash, from a DLL at <project>\native\<name>.dll (package.loadlib may have been
   given a / path). 0 (and out empty) if the module path can't be read or has fewer than two folders. */
static __attribute__((unused)) int pve_project_dir(HMODULE self, char *out, DWORD n) {
    out[0] = 0;
    DWORD len = GetModuleFileNameA(self, out, n);
    if (!len || len >= n) { out[0] = 0; return 0; }
    for (char *c = out; *c; c++) if (*c == '/') *c = '\\';
    char *s = strrchr(out, '\\');               /* drop the file name */
    if (!s) { out[0] = 0; return 0; }
    *s = 0;
    s = strrchr(out, '\\');                     /* drop native\, keep the separator */
    if (!s) { out[0] = 0; return 0; }
    s[1] = 0;
    return 1;
}

#endif
