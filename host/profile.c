/*
 * profile.c — INI parsing, search path and selection of host profiles
 *
 * See profile.h for the file format and the search order.
 */
#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif
#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "bar_access.h"
#include "profile.h"

#ifdef _WIN32
#define PATH_LIST_SEP ';'
#define DIR_SEP       "\\"
#else
#define PATH_LIST_SEP ':'
#define DIR_SEP       "/"
#endif

static char *trim(char *s)
{
    while (*s && isspace((unsigned char)*s))
        s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1]))
        *--e = '\0';
    return s;
}

static void lower(char *s)
{
    for (; *s; s++)
        *s = (char)tolower((unsigned char)*s);
}

static int parse_u32(const char *s, uint32_t *v)
{
    if (!s || !*s)
        return -1;
    char *end = NULL;
    unsigned long long x = strtoull(s, &end, 0);
    if (end == s || *trim(end) != '\0' || x > 0xFFFFFFFFull)
        return -1;
    *v = (uint32_t)x;
    return 0;
}

int profile_u32(const profile_t *p, const char *key, uint32_t *v)
{
    return parse_u32(profile_str(p, key), v);
}

const char *profile_str(const profile_t *p, const char *key)
{
    if (!p)
        return NULL;
    for (int i = 0; i < p->nkv; i++)
        if (!strcmp(p->kv[i].key, key))
            return p->kv[i].val;
    return NULL;
}

int profile_load(const char *path, profile_t *p)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        perror(path);
        return -1;
    }
    memset(p, 0, sizeof(*p));
    snprintf(p->path, sizeof(p->path), "%s", path);

    char line[512], section[32] = "";
    int ln = 0, rc = 0;
    while (fgets(line, sizeof(line), f)) {
        ln++;
        char *s = trim(line);
        if (!*s || *s == ';' || *s == '#')
            continue;
        if (*s == '[') {
            char *e = strchr(s, ']');
            if (!e) {
                fprintf(stderr, "%s:%d: missing ']'\n", path, ln);
                rc = -1;
                break;
            }
            *e = '\0';
            snprintf(section, sizeof(section), "%s", trim(s + 1));
            lower(section);
            continue;
        }
        char *eq = strchr(s, '=');
        if (!eq || !section[0]) {
            fprintf(stderr, "%s:%d: expected 'key = value' inside a [section]\n", path, ln);
            rc = -1;
            break;
        }
        *eq = '\0';
        char *k = trim(s), *v = trim(eq + 1);
        /* Strip a trailing comment introduced by " ;" or " #". */
        for (char *c = v; *c; c++) {
            if ((*c == ';' || *c == '#') && c > v && isspace((unsigned char)c[-1])) {
                *c = '\0';
                v = trim(v);
                break;
            }
        }
        lower(k);
        if (p->nkv >= PROFILE_MAX_KEYS) {
            fprintf(stderr, "%s:%d: more than %d keys\n", path, ln, PROFILE_MAX_KEYS);
            rc = -1;
            break;
        }
        profile_kv_t *kv = &p->kv[p->nkv++];
        if (snprintf(kv->key, sizeof(kv->key), "%s.%s", section, k) >= (int)sizeof(kv->key) ||
            snprintf(kv->val, sizeof(kv->val), "%s", v) >= (int)sizeof(kv->val)) {
            fprintf(stderr, "%s:%d: key or value too long\n", path, ln);
            rc = -1;
            break;
        }
    }
    fclose(f);
    if (rc != 0)
        return rc;

    const char *name = profile_str(p, "profile.name");
    if (!name || !*name) {
        fprintf(stderr, "%s: [profile] name missing\n", path);
        return -1;
    }
    char tmp[sizeof(p->name)];
    snprintf(tmp, sizeof(tmp), "%s", name);
    memcpy(p->name, tmp, sizeof(p->name));
    if (profile_u32(p, "profile.shell_id", &p->shell_id) != 0 ||
        profile_u32(p, "profile.caps", &p->caps) != 0) {
        fprintf(stderr, "%s: [profile] shell_id and caps must be integers\n", path);
        return -1;
    }
    if (profile_str(p, "profile.caps2") && profile_u32(p, "profile.caps2", &p->caps2) != 0) {
        fprintf(stderr, "%s: [profile] caps2 must be an integer\n", path);
        return -1;
    }
    return 0;
}

static int is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int add_dir(char dirs[][PROFILE_PATH_LEN], int n, int max, const char *d)
{
    if (n >= max || !d || !*d)
        return n;
    for (int i = 0; i < n; i++)
        if (!strcmp(dirs[i], d))
            return n;
    snprintf(dirs[n], PROFILE_PATH_LEN, "%s", d);
    return n + 1;
}

int profile_dirs(char dirs[][PROFILE_PATH_LEN], int max)
{
    int n = 0;
    char buf[PROFILE_PATH_LEN];

    const char *env = getenv("FPGA1768_PROFILES");
    if (env && *env) {
        const char *s = env;
        while (*s) {
            const char *e = strchr(s, PATH_LIST_SEP);
            size_t len = e ? (size_t)(e - s) : strlen(s);
            if (len > 0 && len < sizeof(buf)) {
                memcpy(buf, s, len);
                buf[len] = '\0';
                n = add_dir(dirs, n, max, buf);
            }
            if (!e)
                break;
            s = e + 1;
        }
    }

    char exe[PROFILE_PATH_LEN - 32];
    if (plat_exe_dir(exe, sizeof(exe)) == 0) {
        snprintf(buf, sizeof(buf), "%s" DIR_SEP "profiles", exe);
        n = add_dir(dirs, n, max, buf);
        snprintf(buf, sizeof(buf), "%s" DIR_SEP ".." DIR_SEP "profiles", exe);
        n = add_dir(dirs, n, max, buf);
    }
    n = add_dir(dirs, n, max, "profiles");
    n = add_dir(dirs, n, max, "host" DIR_SEP "profiles");
    return n;
}

static int has_ini_suffix(const char *name)
{
    size_t n = strlen(name);
    if (n < 5)
        return 0;
    const char *e = name + n - 4;
    return (e[0] == '.') && tolower((unsigned char)e[1]) == 'i' &&
           tolower((unsigned char)e[2]) == 'n' && tolower((unsigned char)e[3]) == 'i';
}

static int cmp_name(const void *a, const void *b)
{
    return strcmp(((const profile_t *)a)->name, ((const profile_t *)b)->name);
}

int profile_load_all(profile_t **out)
{
    char dirs[8][PROFILE_PATH_LEN];
    int nd = profile_dirs(dirs, 8);
    profile_t *all = calloc(PROFILE_MAX_FILES, sizeof(profile_t));
    int n = 0;
    if (!all) {
        *out = NULL;
        return 0;
    }
    for (int d = 0; d < nd; d++) {
        if (!is_dir(dirs[d]))
            continue;
        DIR *dp = opendir(dirs[d]);
        if (!dp)
            continue;
        struct dirent *de;
        while ((de = readdir(dp)) != NULL && n < PROFILE_MAX_FILES) {
            if (!has_ini_suffix(de->d_name))
                continue;
            char path[PROFILE_PATH_LEN];
            if (snprintf(path, sizeof(path), "%s" DIR_SEP "%s", dirs[d], de->d_name) >=
                (int)sizeof(path))
                continue;
            if (profile_load(path, &all[n]) != 0)
                continue;
            int dup = 0;
            for (int i = 0; i < n; i++)
                if (!strcmp(all[i].name, all[n].name))
                    dup = 1;
            if (!dup)
                n++;
        }
        closedir(dp);
    }
    qsort(all, (size_t)n, sizeof(profile_t), cmp_name);
    *out = all;
    return n;
}

profile_t *profile_find(const char *name_or_path)
{
    profile_t *p = malloc(sizeof(profile_t));
    if (!p)
        return NULL;
    if (has_ini_suffix(name_or_path) && profile_load(name_or_path, p) == 0)
        return p;
    profile_t *all;
    int n = profile_load_all(&all);
    for (int i = 0; i < n; i++) {
        if (!strcmp(all[i].name, name_or_path)) {
            *p = all[i];
            free(all);
            return p;
        }
    }
    free(all);
    free(p);
    return NULL;
}

profile_t *profile_match(uint32_t shell_id)
{
    profile_t *all;
    int n = profile_load_all(&all);
    for (int i = 0; i < n; i++) {
        if (all[i].shell_id == shell_id) {
            profile_t *p = malloc(sizeof(profile_t));
            if (p)
                *p = all[i];
            free(all);
            return p;
        }
    }
    free(all);
    return NULL;
}

const char *caps_text(uint32_t caps, char *buf, unsigned len)
{
    static const char *names[5] = { "DDR4", "I2C", "PR", "FLASH", "DMA" };
    buf[0] = '\0';
    size_t used = 0;
    for (int b = 0; b < 32; b++) {
        if (!((caps >> b) & 1u))
            continue;
        char tmp[16];
        if (b < 5)
            snprintf(tmp, sizeof(tmp), "%s", names[b]);
        else
            snprintf(tmp, sizeof(tmp), "bit%d", b);
        int w = snprintf(buf + used, len - used, "%s%s", used ? " " : "", tmp);
        if (w < 0 || (size_t)w >= len - used)
            break;
        used += (size_t)w;
    }
    if (!used)
        snprintf(buf, len, "none");
    return buf;
}
