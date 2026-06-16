/* Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be
 * found in the LICENSE file. */

#ifndef AVFORMAT_CA_BUNDLE_H
#define AVFORMAT_CA_BUNDLE_H

#include <openssl/ssl.h>

/* The CA root bundle (Mozilla set, PEM bytes) compiled into the binary.
 * Defined in ca_bundle_data.c, which the build generates from cacert.pem. */
extern const unsigned char ff_ca_bundle_pem[];
extern const unsigned int  ff_ca_bundle_pem_len;

/* Load the compiled-in CA roots into ctx's verification store. Returns 0 if
 * at least one certificate was added, a negative value otherwise. Roots
 * already present in the store are skipped silently. */
int ff_load_embedded_ca(SSL_CTX *ctx);

#endif /* AVFORMAT_CA_BUNDLE_H */
