// Prints a fresh X25519 keypair for a mailing relay, with WebCrypto only:
//   RELAY_SEALING_KEY  the raw 32-byte private key, base64url: the value of the Worker secret
//   public             the x25519: form for the `relay` message's encryption_key
// Keep the private line out of the repository and out of logs; the public line is not secret.
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");

const { privateKey, publicKey } = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey));
const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", publicKey));

console.log(`RELAY_SEALING_KEY=${b64url(pkcs8.slice(-32))}`);
console.log(`public=x25519:${b64url(publicRaw)}`);
