#include "CTransfer.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

struct ATRequest {
    CURL *curl;
    atomic_int cancelled;
    char error[CURL_ERROR_SIZE];
    char *result;
    size_t length;
    char *host_key;
    char *fingerprint;
    ATProgress progress;
    void *context;
    double last_progress;
};
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static size_t collect(char *data, size_t size, size_t count, void *ctx) {
    ATRequest *r = ctx;
    size_t n = size * count;
    if (n > 32 * 1024 * 1024 || r->length > 32 * 1024 * 1024 - n) return 0;
    char *p = realloc(r->result, r->length + n + 1);
    if (!p) return 0;
    r->result = p;
    memcpy(p + r->length, data, n);
    r->length += n;
    p[r->length] = 0;
    return n;
}
static int progress(void *ctx, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    ATRequest *r = ctx;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec + now.tv_nsec / 1000000000.0;
    if (r->progress && (seconds - r->last_progress >= 0.1 || (dn + un == dt + ut && dt + ut > 0))) {
        r->last_progress = seconds;
        r->progress(r->context, dn + un, dt + ut);
    }
    return atomic_load(&r->cancelled);
}
static int hostkey(void *ctx, int type, const char *key, size_t length) {
    (void)type;
    ATRequest *r = ctx;
    free(r->host_key);
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t encoded_length = 4 * ((length + 2) / 3);
    r->host_key = malloc(encoded_length + 1);
    if (!r->host_key) return CURLE_OUT_OF_MEMORY;
    for (size_t i = 0, j = 0; i < length; i += 3) {
        unsigned a = (unsigned char)key[i];
        unsigned b = i + 1 < length ? (unsigned char)key[i+1] : 0;
        unsigned c = i + 2 < length ? (unsigned char)key[i+2] : 0;
        r->host_key[j++] = alphabet[a >> 2];
        r->host_key[j++] = alphabet[((a & 3) << 4) | (b >> 4)];
        r->host_key[j++] = i + 1 < length ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
        r->host_key[j++] = i + 2 < length ? alphabet[c & 63] : '=';
    }
    r->host_key[encoded_length] = 0;
    if (r->fingerprint && strcmp(r->fingerprint, r->host_key) == 0) return CURLKHMATCH_OK;
    return CURLKHMATCH_MISMATCH;
}
ATRequest *at_create(const char *url, const char *user, const char *password,
                    const char *key, const char *passphrase, const char *fingerprint) {
    pthread_once(&initialized, initialize);
    ATRequest *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    atomic_init(&r->cancelled, 0);
    r->curl = curl_easy_init();
    if (!r->curl) { free(r); return NULL; }
    if (fingerprint && *fingerprint) r->fingerprint = strdup(fingerprint);
    curl_easy_setopt(r->curl, CURLOPT_URL, url);
    curl_easy_setopt(r->curl, CURLOPT_USERNAME, user);
    curl_easy_setopt(r->curl, CURLOPT_PASSWORD, password);
    curl_easy_setopt(r->curl, CURLOPT_ERRORBUFFER, r->error);
    curl_easy_setopt(r->curl, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(r->curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(r->curl, CURLOPT_LOW_SPEED_TIME, 30L);
    curl_easy_setopt(r->curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(r->curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(r->curl, CURLOPT_XFERINFOFUNCTION, progress);
    curl_easy_setopt(r->curl, CURLOPT_XFERINFODATA, r);
    curl_easy_setopt(r->curl, CURLOPT_PROTOCOLS_STR, "ftp,ftps,sftp");
    curl_easy_setopt(r->curl, CURLOPT_PROXY, "");
    if (strncmp(url, "sftp:", 5) == 0) {
        curl_easy_setopt(r->curl, CURLOPT_SSH_HOSTKEYFUNCTION, hostkey);
        curl_easy_setopt(r->curl, CURLOPT_SSH_HOSTKEYDATA, r);
        if (key && *key) {
            curl_easy_setopt(r->curl, CURLOPT_SSH_PRIVATE_KEYFILE, key);
            curl_easy_setopt(r->curl, CURLOPT_KEYPASSWD, passphrase);
            curl_easy_setopt(r->curl, CURLOPT_SSH_AUTH_TYPES, CURLSSH_AUTH_PUBLICKEY);
        } else curl_easy_setopt(r->curl, CURLOPT_SSH_AUTH_TYPES, CURLSSH_AUTH_PASSWORD);
    }
    return r;
}
void at_cancel(ATRequest *r) { atomic_store(&r->cancelled, 1); }
void at_destroy(ATRequest *r) {
    if (!r) return;
    curl_easy_cleanup(r->curl);
    free(r->result); free(r->host_key); free(r->fingerprint); free(r);
}
int at_perform(ATRequest *r, int mode, const char *local, const char *commands, ATProgress p, void *ctx) {
    r->progress = p; r->context = ctx;
    FILE *f = NULL;
    struct curl_slist *quotes = NULL;
    if (mode == 0) {
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
    } else if (mode == 1 || mode == 2) {
        f = fopen(local, mode == 1 ? "wbx" : "rb");
        if (!f) { snprintf(r->error, sizeof(r->error), "Cannot open local transfer file"); return CURLE_READ_ERROR; }
        if (mode == 1) curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, f);
        else {
            struct stat st;
            if (fstat(fileno(f), &st) != 0) { fclose(f); return CURLE_READ_ERROR; }
            curl_easy_setopt(r->curl, CURLOPT_UPLOAD, 1L);
            curl_easy_setopt(r->curl, CURLOPT_READDATA, f);
            curl_easy_setopt(r->curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)st.st_size);
            curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
            curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
        }
    } else {
        char *copy = strdup(commands);
        char *save = NULL;
        for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) quotes = curl_slist_append(quotes, line);
        free(copy);
        curl_easy_setopt(r->curl, CURLOPT_QUOTE, quotes);
        curl_easy_setopt(r->curl, CURLOPT_NOBODY, 1L);
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
    }
    CURLcode code = curl_easy_perform(r->curl);
    if (f && fclose(f) != 0 && code == CURLE_OK) { snprintf(r->error, sizeof(r->error), "Cannot flush local file"); code = CURLE_WRITE_ERROR; }
    curl_slist_free_all(quotes);
    if (code != CURLE_OK && !r->error[0]) snprintf(r->error, sizeof(r->error), "%s", curl_easy_strerror(code));
    return code;
}
const char *at_error(ATRequest *r) { return r->error; }
const char *at_result(ATRequest *r) { return r->result ? r->result : ""; }
const char *at_host_key(ATRequest *r) { return r->host_key ? r->host_key : ""; }
