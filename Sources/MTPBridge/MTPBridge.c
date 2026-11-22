#include "MTPBridge.h"
#include <libmtp.h>
#include <pthread.h>
#include <stdlib.h>

struct GalaxyMTPSession {
    LIBMTP_mtpdevice_t *device;
};

GalaxyMTPResult galaxy_mtp_open(uint16_t vendor_id, uint16_t product_id, GalaxyMTPSession **session) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, LIBMTP_Init);
    *session = NULL;

    LIBMTP_raw_device_t *devices = NULL;
    int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if (result != LIBMTP_ERROR_NONE) {
        free(devices);
        return result == LIBMTP_ERROR_NO_DEVICE_ATTACHED ? GALAXY_MTP_UNAVAILABLE : GALAXY_MTP_OPEN_FAILED;
    }

    LIBMTP_raw_device_t *match = NULL;
    for (int i = 0; i < count; ++i) {
        LIBMTP_device_entry_t entry = devices[i].device_entry;
        if (entry.vendor_id != vendor_id || entry.product_id != product_id)
            continue;
        if (match) {
            free(devices);
            return GALAXY_MTP_AMBIGUOUS;
        }
        match = &devices[i];
    }
    if (!match) {
        free(devices);
        return GALAXY_MTP_UNAVAILABLE;
    }

    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(match);
    free(devices);
    if (!device)
        return GALAXY_MTP_OPEN_FAILED;

    *session = malloc(sizeof(**session));
    if (!*session) {
        LIBMTP_Release_Device(device);
        return GALAXY_MTP_OPEN_FAILED;
    }
    (*session)->device = device;
    return GALAXY_MTP_OK;
}

void galaxy_mtp_close(GalaxyMTPSession *session) {
    if (session) {
        LIBMTP_Release_Device(session->device);
        free(session);
    }
}

GalaxyMTPResult galaxy_mtp_storages(GalaxyMTPSession *session, GalaxyMTPStorageVisitor visit, void *context) {
    LIBMTP_mtpdevice_t *device = session->device;
    LIBMTP_Clear_Errorstack(device);
    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0 || !device->storage)
        return GALAXY_MTP_STORAGE_UNAVAILABLE;

    for (LIBMTP_devicestorage_t *storage = device->storage; storage; storage = storage->next)
        visit(storage->id, storage->StorageDescription, context);
    return GALAXY_MTP_OK;
}

GalaxyMTPResult galaxy_mtp_list(GalaxyMTPSession *session, uint32_t storage_id, uint32_t parent_id,
                               GalaxyMTPFileVisitor visit, void *context) {
    LIBMTP_mtpdevice_t *device = session->device;
    LIBMTP_Clear_Errorstack(device);
    uint32_t *children = NULL;
    int count = LIBMTP_Get_Children(device, storage_id, parent_id, &children);
    if (count < 0)
        return GALAXY_MTP_READ_FAILED;

    GalaxyMTPResult result = GALAXY_MTP_OK;
    for (int i = 0; i < count; ++i) {
        LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(device, children[i]);
        if (!file) {
            result = GALAXY_MTP_READ_FAILED;
            break;
        }
        visit(file->item_id, file->filename, file->filetype == LIBMTP_FILETYPE_FOLDER, file->filesize, context);
        LIBMTP_destroy_file_t(file);
    }
    free(children);
    return result;
}

GalaxyMTPResult galaxy_mtp_download(GalaxyMTPSession *session, uint32_t object_id, int fd,
                                   GalaxyMTPProgress progress, const void *context) {
    LIBMTP_mtpdevice_t *device = session->device;
    LIBMTP_Clear_Errorstack(device);
    if (LIBMTP_Get_File_To_File_Descriptor(device, object_id, fd, progress, context) == 0)
        return GALAXY_MTP_OK;

    for (LIBMTP_error_t *error = LIBMTP_Get_Errorstack(device); error; error = error->next) {
        if (error->errornumber == LIBMTP_ERROR_CANCELLED)
            return GALAXY_MTP_CANCELLED;
    }
    return GALAXY_MTP_READ_FAILED;
}
