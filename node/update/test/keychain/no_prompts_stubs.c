/* Keychain calls of this process fail instead of asking a person. */
#include <caml/mlvalues.h>

#ifdef __APPLE__
#include <Security/Security.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

CAMLprim value digestif_test_keychain_no_prompts(value unit)
{
  (void)unit;
#ifdef __APPLE__
  SecKeychainSetUserInteractionAllowed(0);
#endif
  return Val_unit;
}
