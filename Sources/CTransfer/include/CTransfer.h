#ifndef CTRANSFER_H
#define CTRANSFER_H
#include <stddef.h>
#include <stdint.h>
typedef struct ATRequest ATRequest;
typedef void (*ATProgress)(void *, int64_t, int64_t);
ATRequest *at_create(const char *url, const char *user, const char *password,
                     const char *private_key, const char *passphrase, const char *fingerprint);
void at_destroy(ATRequest *request);
void at_cancel(ATRequest *request);
void at_pause(ATRequest *request, int paused);
void at_rate_limit(ATRequest *request, int64_t bytes_per_second);
// mode: 0 listing, 1 download, 2 upload, 3 quote commands
int at_perform(ATRequest *request, int mode, const char *local_path, const char *commands,
               ATProgress progress, void *context);
const char *at_error(ATRequest *request);
const char *at_result(ATRequest *request);
const char *at_host_key(ATRequest *request);
#endif
