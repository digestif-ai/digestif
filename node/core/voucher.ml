(* A founding voucher (docs/protocol.md, Hosted circles): a member of a circle a relay already hosts
   vouches for a new circle's root, so the relay hosts it. The document names the new root, the
   relay's host, the vouching circle's root, the member's device key and an expiry at most ten
   minutes out; the device key signs the domain line plus the document's exact bytes. It travels in
   the Digestif-Voucher header of the root's bootstrap append as <document b64url>.<signature>.
   conformance/src/voucher.ts is the relay's reading of the same bytes. *)

let domain = "DIGESTIF-VOUCHER-V0\n"
let format = "digestif-voucher-v0"
let header = "Digestif-Voucher"

(* The longest a voucher stays good: a founding asks its relays within minutes of signing. *)
let ttl_seconds = 600.

(* The Digestif-Voucher header [device] signs for [root] on the relay at [relay] (its base url or a
   circle's address there), vouched by the circle whose root is [circle]. Expires [ttl_seconds] after
   [now], less a second so a relay whose clock runs a little behind never reads it as longer. *)
let sign ?(now = Unix.gettimeofday ()) (device : Crypto.signing_key) ~root
    ~relay ~circle =
  let document : Yojson.Safe.t =
    `Assoc
      [
        ("format", `String format);
        ("root", `String root);
        ("relay", `String (Relay_url.voucher_host relay));
        ("circle", `String circle);
        ("key", `String (Keys.public device));
        ("expires_at", `String (Time_fmt.of_unix (now +. ttl_seconds -. 1.)));
      ]
  in
  let bytes = Jcs.encode document in
  B64url.encode bytes ^ "." ^ Keys.sign device (domain ^ bytes)
