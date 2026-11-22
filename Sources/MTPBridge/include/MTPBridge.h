#ifndef GALAXY_MTP_BRIDGE_H
#define GALAXY_MTP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct GalaxyMTPSession GalaxyMTPSession;

typedef enum {
    GALAXY_MTP_OK,
    GALAXY_MTP_UNAVAILABLE,
    GALAXY_MTP_AMBIGUOUS,
    GALAXY_MTP_OPEN_FAILED,
    GALAXY_MTP_STORAGE_UNAVAILABLE,
    GALAXY_MTP_READ_FAILED,
    GALAXY_MTP_CANCELLED
} GalaxyMTPResult;

typedef void (*GalaxyMTPStorageVisitor)(uint32_t id, const char *name, void *context);
typedef void (*GalaxyMTPFileVisitor)(uint32_t id, const char *name, bool is_folder,
                                     uint64_t size, void *context);
typedef int (*GalaxyMTPProgress)(uint64_t completed, uint64_t total, const void *context);

// Keep a session and all its operations on a single serial queue. The visitor's
// strings are borrowed and only valid during the callback.
GalaxyMTPResult galaxy_mtp_open(uint16_t vendor_id, uint16_t product_id, GalaxyMTPSession **session);
void galaxy_mtp_close(GalaxyMTPSession *session);
GalaxyMTPResult galaxy_mtp_storages(GalaxyMTPSession *session, GalaxyMTPStorageVisitor visit, void *context);
GalaxyMTPResult galaxy_mtp_list(GalaxyMTPSession *session, uint32_t storage_id, uint32_t parent_id,
                               GalaxyMTPFileVisitor visit, void *context);
GalaxyMTPResult galaxy_mtp_download(GalaxyMTPSession *session, uint32_t object_id, int fd,
                                   GalaxyMTPProgress progress, const void *context);

#endif
