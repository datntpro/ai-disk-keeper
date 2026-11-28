#ifndef CNVMESMART_H
#define CNVMESMART_H

#include <stdint.h>

/// Size of the NVMe SMART / Health information page (log 02h).
#define ADK_NVME_SMART_PAGE_SIZE 512

/// Reads the NVMe SMART/Health page of the internal NVMe disk through Apple's public IOKit plug-in
/// (`IOKit/storage/nvme/NVMeSMARTLibExternal.h`). Read-only: it only calls `SMARTReadData`.
/// No root, no entitlement, no subprocess.
///
/// Returns 0 on success (`out` holds the raw page), otherwise an `IOReturn` / kern error code, or:
///   -1 no internal disk reports "NVMe SMART Capable" (virtual disk, external enclosure)
///   -2 the plug-in interface has an unsupported version
int32_t adk_nvme_smart_read(uint8_t out[ADK_NVME_SMART_PAGE_SIZE]);

#endif
