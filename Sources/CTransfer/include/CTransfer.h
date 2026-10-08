#ifndef CTRANSFER_H
#define CTRANSFER_H
#include <stddef.h>
#include <stdint.h>
typedef struct ATRequest ATRequest;
typedef void (*ATProgress)(void *, int64_t, int64_t);
// A NULL buffer resets the streaming sink at the start of a new HTTP response.
typedef void (*ATBody)(void *, const void *, size_t);
ATRequest *at_create(const char *url, const char *user, const char *password,
                     const char *private_key, const char *passphrase, const char *fingerprint);
void at_destroy(ATRequest *request);
void at_cancel(ATRequest *request);
void at_pause(ATRequest *request, int paused);
void at_rate_limit(ATRequest *request, int64_t bytes_per_second);
void at_download_limit(ATRequest *request, int64_t maximum_bytes);
int at_transfer_window(ATRequest *request, int64_t offset, int64_t end, int64_t total);
void at_body_sink(ATRequest *request, ATBody sink, void *context);
int64_t at_file_size(ATRequest *request);
int64_t at_file_time(ATRequest *request);
const char *at_etag(ATRequest *request);
int64_t at_body_bytes(ATRequest *request);
int at_tls(ATRequest *request, int required, const char *certificate_authority);
int at_http(ATRequest *request, const char *method, const char *headers, const char *body);
int at_s3(ATRequest *request);
// A multipart part reads this exact source-file slice; no whole-file buffer or copy.
int at_upload_window(ATRequest *request, int64_t start, int64_t length);
long at_response_code(ATRequest *request);
// mode: 0 listing, 1 download, 2 upload, 3 quote, 4 HTTP command, 5 streaming digest, 6 stat
int at_perform(ATRequest *request, int mode, const char *local_path, const char *commands,
               ATProgress progress, void *context);
const char *at_error(ATRequest *request);
const char *at_result(ATRequest *request);
const char *at_host_key(ATRequest *request);
#endif
