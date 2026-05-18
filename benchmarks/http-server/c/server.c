// GET /users/<id> -> JSON. libmicrohttpd + yyjson, thread pool sized to nproc.
//
// Build:
//   sudo apt-get install -y libmicrohttpd-dev
//   (drop yyjson.h + yyjson.c next to this file from https://github.com/ibireme/yyjson)
//   gcc -O2 -pthread -o c-server server.c yyjson.c -lmicrohttpd

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <microhttpd.h>
#include "yyjson.h"

#define PORT 8080

static enum MHD_Result handle(
    void *cls, struct MHD_Connection *conn,
    const char *url, const char *method,
    const char *version,
    const char *upload_data, size_t *upload_data_size,
    void **req_cls)
{
    (void)cls; (void)version; (void)upload_data; (void)upload_data_size;

    if (*req_cls == NULL) { *req_cls = (void *)1; return MHD_YES; }

    if (strcmp(method, "GET") != 0 || strncmp(url, "/users/", 7) != 0) {
        struct MHD_Response *r = MHD_create_response_from_buffer(0, NULL, MHD_RESPMEM_PERSISTENT);
        enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_NOT_FOUND, r);
        MHD_destroy_response(r);
        return ret;
    }

    const char *id_str = url + 7;
    int id = atoi(id_str);

    char name[64], email[96];
    int name_len  = snprintf(name,  sizeof name,  "User %s",            id_str);
    int email_len = snprintf(email, sizeof email, "user%s@example.com", id_str);

    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
    yyjson_mut_val *root = yyjson_mut_obj(doc);
    yyjson_mut_doc_set_root(doc, root);
    yyjson_mut_obj_add_int(doc, root, "id",      id);
    yyjson_mut_obj_add_strn(doc, root, "name",   name,  (size_t)name_len);
    yyjson_mut_obj_add_strn(doc, root, "email",  email, (size_t)email_len);
    yyjson_mut_obj_add_int(doc, root, "created", 1737000000);

    size_t body_len = 0;
    char *body = yyjson_mut_write(doc, 0, &body_len);

    struct MHD_Response *r = MHD_create_response_from_buffer(body_len, body, MHD_RESPMEM_MUST_FREE);
    MHD_add_response_header(r, "Content-Type", "application/json");
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_OK, r);
    MHD_destroy_response(r);
    yyjson_mut_doc_free(doc);
    return ret;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int cores = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (cores < 1) cores = 1;

    fprintf(stderr, "listening on :%d (%d threads)\n", PORT, cores);

    struct MHD_Daemon *d = MHD_start_daemon(
        MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_EPOLL,
        PORT, NULL, NULL,
        &handle, NULL,
        MHD_OPTION_THREAD_POOL_SIZE,   (unsigned int)cores,
        MHD_OPTION_CONNECTION_LIMIT,   (unsigned int)16384,
        MHD_OPTION_CONNECTION_TIMEOUT, (unsigned int)65,
        MHD_OPTION_END);

    if (!d) { fprintf(stderr, "MHD_start_daemon failed\n"); return 1; }

    pause();
    MHD_stop_daemon(d);
    return 0;
}
