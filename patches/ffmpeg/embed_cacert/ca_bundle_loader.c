/* Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be
 * found in the LICENSE file. */

#include "ca_bundle.h"

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

int ff_load_embedded_ca(SSL_CTX *ctx)
{
    BIO *mem;
    X509_STORE *store;
    X509 *x;
    int n = 0;

    if (!ctx)
        return -1;
    store = SSL_CTX_get_cert_store(ctx);
    mem   = BIO_new_mem_buf(ff_ca_bundle_pem, (int)ff_ca_bundle_pem_len);
    if (!store || !mem) {
        if (mem)
            BIO_free(mem);
        return -1;
    }

    /* PEM_read_bio_X509 advances the BIO across the concatenated roots. */
    while ((x = PEM_read_bio_X509(mem, NULL, NULL, NULL))) {
        /* A duplicate add fails harmlessly — the root is already trusted. */
        if (X509_STORE_add_cert(store, x) == 1)
            n++;
        X509_free(x); /* the store holds its own reference */
    }
    /* The terminating read leaves a benign PEM_R_NO_START_LINE on the queue. */
    ERR_clear_error();
    BIO_free(mem);
    return n > 0 ? 0 : -1;
}
