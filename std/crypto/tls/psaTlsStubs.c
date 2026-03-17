/* PSA ITS stubs — persistent key storage not used in MetaScript TLS.
 * psa_crypto_storage.c calls these; we stub them to return NOT_SUPPORTED. */
#include <stdint.h>
#include <stddef.h>

typedef uint64_t psa_storage_uid_t;
typedef int32_t psa_status_t;

typedef struct {
	uint32_t capacity;
	uint32_t size;
	uint32_t flags;
} psa_storage_info_t;

#define PSA_ERROR_DOES_NOT_EXIST ((psa_status_t)-140)
#define PSA_ERROR_NOT_SUPPORTED  ((psa_status_t)-134)

psa_status_t psa_its_get_info(psa_storage_uid_t uid, psa_storage_info_t *p_info) {
	(void)uid; (void)p_info;
	return PSA_ERROR_DOES_NOT_EXIST;
}

psa_status_t psa_its_get(psa_storage_uid_t uid, uint32_t data_offset,
                         uint32_t data_size, void *p_data, size_t *p_data_length) {
	(void)uid; (void)data_offset; (void)data_size; (void)p_data; (void)p_data_length;
	return PSA_ERROR_DOES_NOT_EXIST;
}

psa_status_t psa_its_set(psa_storage_uid_t uid, uint32_t data_length,
                         const void *p_data, uint32_t create_flags) {
	(void)uid; (void)data_length; (void)p_data; (void)create_flags;
	return PSA_ERROR_NOT_SUPPORTED;
}

psa_status_t psa_its_remove(psa_storage_uid_t uid) {
	(void)uid;
	return PSA_ERROR_DOES_NOT_EXIST;
}
