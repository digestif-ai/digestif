/* The login Keychain, read and written by the calling binary itself (Keychain): the signing job's
   pinned digestif-update creates its own items, so their access list trusts that binary alone,
   and reads them back silently. On any other system every call answers -1 and says why. Each
   call answers (status, bytes): 0 and the item's data or nothing, or the OSStatus and its message. */

#define CAML_NAME_SPACE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

static value answer(int status, const char *bytes, size_t len)
{
  CAMLparam0();
  CAMLlocal2(r, s);
  s = caml_alloc_initialized_string(len, bytes);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, Val_int(status));
  Store_field(r, 1, s);
  CAMLreturn(r);
}

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

static char *copy(value v)
{
  size_t len = caml_string_length(v);
  char *c = malloc(len + 1);
  if (c != NULL) {
    memcpy(c, String_val(v), len);
    c[len] = '\0';
  }
  return c;
}

static value failure(OSStatus st)
{
  char buf[512];
  CFStringRef m = SecCopyErrorMessageString(st, NULL);
  if (m == NULL || !CFStringGetCString(m, buf, sizeof buf, kCFStringEncodingUTF8))
    snprintf(buf, sizeof buf, "OSStatus %d", (int)st);
  if (m != NULL) CFRelease(m);
  return answer(st == errSecSuccess ? -1 : (int)st, buf, strlen(buf));
}

static CFMutableDictionaryRef query_for(const char *service)
{
  CFMutableDictionaryRef q = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFStringRef s = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
  CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(q, kSecAttrService, s);
  CFRelease(s);
  return q;
}

CAMLprim value digestif_keychain_read(value v_service)
{
  CAMLparam1(v_service);
  CAMLlocal1(r);
  char *service = copy(v_service);
  if (service == NULL) CAMLreturn(answer(-1, "out of memory", 13));
  CFMutableDictionaryRef q = query_for(service);
  free(service);
  CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
  CFTypeRef data = NULL;
  /* A read the Keychain asks the person about blocks until they answer. */
  caml_enter_blocking_section();
  OSStatus st = SecItemCopyMatching(q, &data);
  caml_leave_blocking_section();
  CFRelease(q);
  if (st != errSecSuccess || data == NULL) CAMLreturn(failure(st));
  r = answer(0, (const char *)CFDataGetBytePtr((CFDataRef)data),
             (size_t)CFDataGetLength((CFDataRef)data));
  CFRelease(data);
  CAMLreturn(r);
}

/* Every item of [service] is deleted, then one is added holding [data]. An item added with no
   access of its own trusts exactly the application that added it: this binary. */
CAMLprim value digestif_keychain_store(value v_service, value v_account, value v_label,
                                       value v_data)
{
  CAMLparam4(v_service, v_account, v_label, v_data);
  char *service = copy(v_service);
  char *account = copy(v_account);
  char *label = copy(v_label);
  size_t len = caml_string_length(v_data);
  UInt8 *bytes = malloc(len > 0 ? len : 1);
  if (service == NULL || account == NULL || label == NULL || bytes == NULL) {
    free(service); free(account); free(label); free(bytes);
    CAMLreturn(answer(-1, "out of memory", 13));
  }
  memcpy(bytes, String_val(v_data), len);
  CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)len);
  memset(bytes, 0, len);
  free(bytes);
  CFMutableDictionaryRef q = query_for(service);
  CFMutableDictionaryRef attrs = query_for(service);
  free(service);
  CFStringRef a = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
  CFStringRef l = CFStringCreateWithCString(NULL, label, kCFStringEncodingUTF8);
  free(account);
  free(label);
  CFDictionarySetValue(attrs, kSecAttrAccount, a);
  CFDictionarySetValue(attrs, kSecAttrLabel, l);
  CFDictionarySetValue(attrs, kSecValueData, data);
  CFRelease(a);
  CFRelease(l);
  CFRelease(data);
  OSStatus st = errSecSuccess;
  caml_enter_blocking_section();
  /* SecItemDelete on a file keychain removes one match at a time. */
  for (int i = 0; i < 16; i++) {
    st = SecItemDelete(q);
    if (st != errSecSuccess) break;
  }
  if (st == errSecItemNotFound || st == errSecSuccess) st = SecItemAdd(attrs, NULL);
  caml_leave_blocking_section();
  CFRelease(q);
  CFRelease(attrs);
  if (st != errSecSuccess) CAMLreturn(failure(st));
  CAMLreturn(answer(0, "", 0));
}

#else

static const char not_mac[] = "the login Keychain is macOS's; the signing job runs on a Mac";

CAMLprim value digestif_keychain_read(value v_service)
{
  (void)v_service;
  return answer(-1, not_mac, strlen(not_mac));
}

CAMLprim value digestif_keychain_store(value v_service, value v_account, value v_label,
                                       value v_data)
{
  (void)v_service; (void)v_account; (void)v_label; (void)v_data;
  return answer(-1, not_mac, strlen(not_mac));
}

#endif
