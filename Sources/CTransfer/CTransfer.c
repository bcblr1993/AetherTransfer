#include "CTransfer.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <strings.h>

struct ATRequest {
    CURL *curl;
    atomic_int cancelled;
    atomic_int paused;
    char error[CURL_ERROR_SIZE];
    char *result;
    size_t length;
    char *host_key;
    char *fingerprint;
    ATProgress progress;
    void *context;
    double last_progress;
    int64_t last_completed;
    struct curl_slist *headers;
    FILE *download;
    int64_t download_limit;
    int64_t downloaded;
    int64_t offset, range_end, expected_total;
    int window, is_http, mode, valid_range, rejected_range;
    long http_status;
    char etag[1024];
    FILE *upload;
    int upload_window, upload_source_failed;
    int64_t upload_start, upload_length, upload_remaining;
    ATBody sink;
    void *sink_context;
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
static size_t response_header(char *data, size_t size, size_t count, void *ctx) {
    ATRequest *r = ctx;
    size_t n = size * count;
    // Authentication may produce multiple responses. Only retain the final response body.
    if (n >= 5 && memcmp(data, "HTTP/", 5) == 0) {
        char line[64]; size_t copied = n < sizeof(line) - 1 ? n : sizeof(line) - 1;
        memcpy(line, data, copied); line[copied] = 0;
        sscanf(line, "HTTP/%*s %ld", &r->http_status);
        r->length = 0;
        r->downloaded = r->offset;
        r->valid_range = 0; r->etag[0] = 0;
        if (r->sink) r->sink(r->sink_context, NULL, 0);
        if (r->result) r->result[0] = 0;
        if (r->download && (fseeko(r->download, r->offset, SEEK_SET) != 0 || ftruncate(fileno(r->download), r->offset) != 0)) return 0;
    } else if (n > 5 && strncasecmp(data, "ETag:", 5) == 0) {
        size_t start = 5, end = n;
        while (start < end && (data[start] == ' ' || data[start] == '\t')) start++;
        while (end > start && (data[end-1] == '\r' || data[end-1] == '\n' || data[end-1] == ' ')) end--;
        if (end - start < sizeof(r->etag)) { memcpy(r->etag, data + start, end - start); r->etag[end - start] = 0; }
    } else if (n > 14 && strncasecmp(data, "Content-Range:", 14) == 0) {
        char line[256]; size_t copied = n < sizeof(line)-1 ? n : sizeof(line)-1;
        memcpy(line, data, copied); line[copied] = 0;
        long long start, end, total;
        if (sscanf(line + 14, " bytes %lld-%lld/%lld", &start, &end, &total) == 3 &&
            start == r->offset && end >= start && total > end &&
            (r->range_end < 0 || end == r->range_end) && (r->expected_total < 0 || total == r->expected_total)) r->valid_range = 1;
    }
    return n;
}
static int seek_upload(void *ctx, curl_off_t offset, int origin) {
    return fseeko(ctx, (off_t)offset, origin) == 0 ? CURL_SEEKFUNC_OK : CURL_SEEKFUNC_FAIL;
}
static size_t read_upload_slice(char *data, size_t size, size_t count, void *ctx) {
    ATRequest *r = ctx;
    if (size && count > SIZE_MAX / size) { r->upload_source_failed = 1; return CURL_READFUNC_ABORT; }
    size_t n = size * count;
    if ((uint64_t)n > (uint64_t)r->upload_remaining) n = (size_t)r->upload_remaining;
    size_t read = fread(data, 1, n, r->upload);
    r->upload_remaining -= (int64_t)read;
    if (read < n) { r->upload_source_failed = 1; return CURL_READFUNC_ABORT; }
    return read;
}
static int seek_upload_slice(void *ctx, curl_off_t offset, int origin) {
    ATRequest *r = ctx;
    int64_t base = origin == SEEK_SET ? 0 : (origin == SEEK_END ? r->upload_length : r->upload_length - r->upload_remaining);
    if ((origin != SEEK_SET && origin != SEEK_END && origin != SEEK_CUR) || offset < -base || offset > r->upload_length - base)
        return CURL_SEEKFUNC_FAIL;
    int64_t position = base + offset;
    if (fseeko(r->upload, r->upload_start + position, SEEK_SET) != 0) return CURL_SEEKFUNC_FAIL;
    r->upload_remaining = r->upload_length - position;
    return CURL_SEEKFUNC_OK;
}
static size_t write_download(char *data, size_t size, size_t count, void *ctx) {
    ATRequest *r = ctx;
    if (size && count > SIZE_MAX / size) return 0;
    size_t n = size * count;
    // Digest authentication can return a challenge body before the actual ranged response.
    // Discard that body; it is never part of a downloaded file or content digest.
    if (r->is_http && r->http_status == 401) return n;
    if (r->is_http && r->window && (r->offset > 0 || r->range_end >= 0) &&
        (r->http_status != 206 || !r->valid_range)) {
        r->rejected_range = 1; return 0;
    }
    int64_t limit = r->download_limit > 0 ? r->download_limit : (r->window ? r->expected_total : -1);
    if (limit >= 0 && (r->downloaded > limit || (uint64_t)n > (uint64_t)(limit - r->downloaded))) {
        snprintf(r->error, sizeof(r->error), "Remote file exceeds the download size limit");
        return 0;
    }
    size_t written = n;
    if (r->sink) r->sink(r->sink_context, data, n);
    else written = fwrite(data, 1, n, r->download);
    r->downloaded += (int64_t)written;
    return written;
}
static int progress(void *ctx, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    ATRequest *r = ctx;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec + now.tv_nsec / 1000000000.0;
    if (r->progress && (seconds - r->last_progress >= 0.1 || (dn + un != r->last_completed && dn + un == dt + ut && dt + ut > 0))) {
        r->last_progress = seconds;
        r->last_completed = dn + un;
        int64_t base = r->mode == 1 || r->mode == 2 ? r->offset : 0;
        r->progress(r->context, base + dn + un, base + dt + ut);
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
    atomic_init(&r->paused, 0);
    r->range_end = -1; r->expected_total = -1;
    r->is_http = strncmp(url, "http:", 5) == 0 || strncmp(url, "https:", 6) == 0;
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
    curl_easy_setopt(r->curl, CURLOPT_PROTOCOLS_STR, "ftp,ftps,sftp,http,https");
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
int at_http(ATRequest *r, const char *method, const char *headers, const char *body) {
    char *copy = strdup(headers);
    if (!copy) return CURLE_OUT_OF_MEMORY;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        struct curl_slist *next = curl_slist_append(r->headers, line);
        if (!next) { free(copy); return CURLE_OUT_OF_MEMORY; }
        r->headers = next;
    }
    free(copy);
    // GET, HEAD and PUT follow their native transfer modes, including authentication retries.
    // Reserve CUSTOMREQUEST for actual DAV extensions; forcing PUT also forces it onto auth probes.
    CURLcode code = CURLE_OK;
    if (strcmp(method, "GET") != 0 && strcmp(method, "HEAD") != 0 && strcmp(method, "PUT") != 0)
        code = curl_easy_setopt(r->curl, CURLOPT_CUSTOMREQUEST, method);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_HTTPHEADER, r->headers);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_HTTPAUTH, (long)(CURLAUTH_BASIC | CURLAUTH_DIGEST));
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_FOLLOWLOCATION, 0L);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_FAILONERROR, 1L);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_HEADERFUNCTION, response_header);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_HEADERDATA, r);
    if (code == CURLE_OK && body) code = curl_easy_setopt(r->curl, CURLOPT_COPYPOSTFIELDS, body);
    return code;
}
long at_response_code(ATRequest *r) {
    long code = 0;
    curl_easy_getinfo(r->curl, CURLINFO_RESPONSE_CODE, &code);
    return code;
}
int at_s3(ATRequest *r, const char *method) {
    if (!r->is_http) return CURLE_BAD_FUNCTION_ARGUMENT;
    // CryptoKit signs the exact path. Never normalize object keys or retry Basic/Digest.
    CURLcode code = curl_easy_setopt(r->curl, CURLOPT_PATH_AS_IS, 1L);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE);
    // An empty COPYPOSTFIELDS body otherwise selects POST, even when signing PUT.
    // S3 has no Basic/Digest auth probe; its signed method must match every request.
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_CUSTOMREQUEST, method);
    return code;
}
int at_upload_window(ATRequest *r, int64_t start, int64_t length) {
    if (start < 0 || length < 0 || start > INT64_MAX - length) return CURLE_BAD_FUNCTION_ARGUMENT;
    r->upload_window = 1; r->upload_start = start; r->upload_length = length; r->upload_remaining = length;
    return CURLE_OK;
}
void at_cancel(ATRequest *r) { atomic_store(&r->cancelled, 1); }
void at_pause(ATRequest *r, int paused) { atomic_store(&r->paused, paused); }
void at_rate_limit(ATRequest *r, int64_t rate) {
    curl_easy_setopt(r->curl, CURLOPT_MAX_SEND_SPEED_LARGE, (curl_off_t)rate);
    curl_easy_setopt(r->curl, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)rate);
}
int at_tls(ATRequest *r, int required, const char *certificate_authority) {
    CURLcode code = curl_easy_setopt(r->curl, CURLOPT_SSL_VERIFYPEER, 1L);
    if (code == CURLE_OK) code = curl_easy_setopt(r->curl, CURLOPT_SSL_VERIFYHOST, 2L);
    if (code == CURLE_OK && required) code = curl_easy_setopt(r->curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    if (code == CURLE_OK && certificate_authority && *certificate_authority)
        code = curl_easy_setopt(r->curl, CURLOPT_CAINFO, certificate_authority);
    return code;
}
void at_download_limit(ATRequest *r, int64_t maximum_bytes) { r->download_limit = maximum_bytes > 0 ? maximum_bytes : 0; }
int at_transfer_window(ATRequest *r, int64_t offset, int64_t end, int64_t total) {
    if (offset < 0 || (end >= 0 && end < offset) || (total >= 0 && offset > total)) return CURLE_BAD_FUNCTION_ARGUMENT;
    r->window = 1; r->offset = offset; r->range_end = end; r->expected_total = total; r->downloaded = offset;
    if (end >= 0) {
        char range[80]; snprintf(range, sizeof(range), "%lld-%lld", (long long)offset, (long long)end);
        return curl_easy_setopt(r->curl, CURLOPT_RANGE, range);
    }
    return curl_easy_setopt(r->curl, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)offset);
}
void at_body_sink(ATRequest *r, ATBody sink, void *context) { r->sink = sink; r->sink_context = context; }
int64_t at_file_size(ATRequest *r) { curl_off_t size = -1; curl_easy_getinfo(r->curl, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &size); return size; }
int64_t at_file_time(ATRequest *r) { curl_off_t time = -1; curl_easy_getinfo(r->curl, CURLINFO_FILETIME_T, &time); return time; }
const char *at_etag(ATRequest *r) { return r->etag; }
int64_t at_body_bytes(ATRequest *r) { return r->downloaded - r->offset; }
void at_destroy(ATRequest *r) {
    if (!r) return;
    curl_easy_cleanup(r->curl);
    curl_slist_free_all(r->headers);
    free(r->result); free(r->host_key); free(r->fingerprint); free(r);
}
int at_perform(ATRequest *r, int mode, const char *local, const char *commands, ATProgress p, void *ctx) {
    r->progress = p; r->context = ctx; r->mode = mode;
    FILE *f = NULL;
    struct curl_slist *quotes = NULL;
    if (mode == 0) {
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
    } else if (mode == 1 || mode == 2) {
        if (mode == 1 && r->window) {
            int descriptor = open(local, O_RDWR | O_NOFOLLOW);
            if (descriptor >= 0) {
                struct stat st;
                if (fstat(descriptor, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size != r->offset) { close(descriptor); descriptor = -1; }
            }
            if (descriptor >= 0) { f = fdopen(descriptor, "r+b"); if (!f) close(descriptor); }
            if (f && fseeko(f, r->offset, SEEK_SET) != 0) { fclose(f); f = NULL; }
        } else if (mode == 2 && r->upload_window) {
            int descriptor = open(local, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
            if (descriptor >= 0) { f = fdopen(descriptor, "rb"); if (!f) close(descriptor); }
        } else f = fopen(local, mode == 1 ? "wbx" : "rb");
        if (!f) { snprintf(r->error, sizeof(r->error), "Cannot open local transfer file"); return CURLE_READ_ERROR; }
        if (mode == 1) {
            r->download = f;
            curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, write_download);
            curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
        }
        else {
            struct stat st;
            if (fstat(fileno(f), &st) != 0) { fclose(f); return CURLE_READ_ERROR; }
            if (r->upload_window && (!S_ISREG(st.st_mode) || st.st_size < r->upload_start + r->upload_length ||
                                     fseeko(f, r->upload_start, SEEK_SET) != 0)) {
                fclose(f); snprintf(r->error, sizeof(r->error), "Upload source slice is unavailable"); return CURLE_READ_ERROR;
            }
            curl_easy_setopt(r->curl, CURLOPT_UPLOAD, 1L);
            r->upload = f;
            curl_easy_setopt(r->curl, CURLOPT_READFUNCTION, r->upload_window ? read_upload_slice : NULL);
            curl_easy_setopt(r->curl, CURLOPT_READDATA, r->upload_window ? (void *)r : (void *)f);
            curl_easy_setopt(r->curl, CURLOPT_SEEKFUNCTION, r->upload_window ? seek_upload_slice : seek_upload);
            curl_easy_setopt(r->curl, CURLOPT_SEEKDATA, r->upload_window ? (void *)r : (void *)f);
            curl_easy_setopt(r->curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)(r->upload_window ? r->upload_length : st.st_size));
            curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
            curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
        }
    } else if (mode == 5) {
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, write_download);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
    } else if (mode == 6) {
        curl_easy_setopt(r->curl, CURLOPT_NOBODY, 1L);
        curl_easy_setopt(r->curl, CURLOPT_FILETIME, 1L);
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
    } else if (mode == 4) {
        curl_easy_setopt(r->curl, CURLOPT_WRITEFUNCTION, collect);
        curl_easy_setopt(r->curl, CURLOPT_WRITEDATA, r);
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
    CURLcode code = CURLE_FAILED_INIT;
    CURLM *multi = curl_multi_init();
    if (multi && curl_multi_add_handle(multi, r->curl) == CURLM_OK) {
        int running = 1, applied_pause = 0;
        while (running) {
            if (atomic_load(&r->cancelled)) { code = CURLE_ABORTED_BY_CALLBACK; break; }
            if (curl_multi_perform(multi, &running) != CURLM_OK) { code = CURLE_RECV_ERROR; break; }
            int desired_pause = atomic_load(&r->paused);
            if (desired_pause != applied_pause && running) {
                // libcurl APIs remain on the owning worker; the UI only changes an atomic flag.
                code = curl_easy_pause(r->curl, desired_pause ? CURLPAUSE_ALL : CURLPAUSE_CONT);
                if (code != CURLE_OK) break;
                applied_pause = desired_pause;
            }
            if (!running) {
                int messages;
                CURLMsg *message;
                while ((message = curl_multi_info_read(multi, &messages))) {
                    if (message->msg == CURLMSG_DONE) code = message->data.result;
                }
                break;
            }
            if (curl_multi_poll(multi, NULL, 0, 100, NULL) != CURLM_OK) { code = CURLE_RECV_ERROR; break; }
        }
        curl_multi_remove_handle(multi, r->curl);
    }
    if (multi) curl_multi_cleanup(multi);
    if (f && fclose(f) != 0 && code == CURLE_OK) { snprintf(r->error, sizeof(r->error), "Cannot flush local file"); code = CURLE_WRITE_ERROR; }
    r->download = NULL;
    r->upload = NULL;
    if (r->upload_source_failed) {
        snprintf(r->error, sizeof(r->error), "Upload source slice changed or could not be read");
        code = CURLE_READ_ERROR; // Do not classify a read-callback abort as user cancellation.
    }
    curl_slist_free_all(quotes);
    if (r->rejected_range || (code == CURLE_OK && r->is_http && r->window &&
        (r->offset > 0 || r->range_end >= 0) && (r->http_status != 206 || !r->valid_range))) {
        snprintf(r->error, sizeof(r->error), "Server did not return the requested byte range; partial file preserved");
        code = CURLE_RANGE_ERROR;
    }
    if (code != CURLE_OK && !r->error[0]) snprintf(r->error, sizeof(r->error), "%s", curl_easy_strerror(code));
    return code;
}
const char *at_error(ATRequest *r) { return r->error; }
const char *at_result(ATRequest *r) { return r->result ? r->result : ""; }
const char *at_host_key(ATRequest *r) { return r->host_key ? r->host_key : ""; }
