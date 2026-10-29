(* Request signing (protocol.md, Request signing). The signed string is

   DIGESTIF-REQUEST-V0\n<METHOD>\n<path with query, as sent>\n<timestamp>\n<nonce>\n<sha256 hex of body> *)

let prefix = "DIGESTIF-REQUEST-V0"

let signed_string ~meth ~path ~timestamp ~nonce ~body =
  String.concat "\n" [ prefix; String.uppercase_ascii meth; path; timestamp; nonce; Crypto.sha256_hex body ]

let new_nonce () = B64url.encode (Crypto.random 16)

(* The four headers. [key = None] is a bootstrap append (dinner or join): no Digestif-Key and no
   signature, because the signatures inside the body are the proof. *)
let headers ?key ?(timestamp = Time_fmt.now ()) ?(nonce = new_nonce ()) ~meth ~path ~body () =
  let base = [ ("Digestif-Timestamp", timestamp); ("Digestif-Nonce", nonce) ] in
  match key with
  | None -> base
  | Some (k : Crypto.signing_key) ->
      let s = signed_string ~meth ~path ~timestamp ~nonce ~body in
      [ ("Digestif-Key", Keys.public k) ] @ base
      @ [ ("Digestif-Signature", Keys.encode_signature (Crypto.sign k s)) ]

type refusal = Bad_signature | Stale_request | Replayed_nonce

(* The relay side of the check, used by the in-process test relay and by the conformance suite:
   [seen] answers whether this key already used this nonce inside the window, and records it. *)
let verify ~skew_seconds ~now ~seen ~meth ~path ~body headers =
  let h name = List.assoc_opt (String.lowercase_ascii name) (List.map (fun (k, v) -> (String.lowercase_ascii k, v)) headers) in
  match (h "Digestif-Key", h "Digestif-Timestamp", h "Digestif-Nonce", h "Digestif-Signature") with
  | Some key, Some timestamp, Some nonce, Some signature -> (
      match (Keys.decode_ed25519 key, Keys.decode_signature signature, Time_fmt.to_unix timestamp) with
      | Ok pub, Ok sigr, Some t ->
          if not (Crypto.verify ~pub ~signature:sigr (signed_string ~meth ~path ~timestamp ~nonce ~body)) then
            Error Bad_signature
          else if Float.abs (now -. t) > float_of_int skew_seconds then Error Stale_request
          else if seen ~key ~nonce then Error Replayed_nonce
          else Ok key
      | _ -> Error Bad_signature)
  | _ -> Error Bad_signature
