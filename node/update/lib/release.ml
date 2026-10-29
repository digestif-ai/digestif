(* The signed documents of the release channel (docs/releases.md): a release manifest, a key
   revocation, and the detached signatures over either. A signature is over a domain prefix plus the
   document's exact bytes as published, so no canonical encoding is involved and a byte that changes
   after signing breaks every signature. *)

type signer = { name : string; key : Crypto.public_key }
type artifact = { platform : string; url : string; sha256 : string; size : int }

type manifest = {
  version : Version.t;
  published_at : string;
  notes : string;
  artifacts : artifact list;
  signers : signer list option;
      (** Present only on a release that replaces the signer set. *)
}

type revocation = {
  revoked_key : Crypto.public_key;
  reason : string;
  revoked_at : string;
}

type signature = { by : Crypto.public_key; signature : string }

(* A document as fetched: its exact bytes, parsed, and the signatures published beside it. *)
type 'a signed = { bytes : string; doc : 'a; signatures : signature list }

let release_domain = "DIGESTIF-RELEASE-V0\n"
let revocation_domain = "DIGESTIF-REVOCATION-V0\n"
let manifest_format = "digestif-release-v0"
let revocation_format = "digestif-revocation-v0"
let ( let* ) = Result.bind
let field name = function `Assoc kv -> List.assoc_opt name kv | _ -> None

let string_field name json =
  match field name json with
  | Some (`String s) -> Ok s
  | _ -> Error (Printf.sprintf "field %S must be a string" name)

let optional_string name json =
  match field name json with
  | None | Some `Null -> Ok ""
  | Some (`String s) -> Ok s
  | _ -> Error (Printf.sprintf "field %S must be a string" name)

let int_field name json =
  match field name json with
  | Some (`Int i) when i >= 0 -> Ok i
  | _ -> Error (Printf.sprintf "field %S must be a non-negative integer" name)

let list_field name json =
  match field name json with
  | Some (`List l) -> Ok l
  | _ -> Error (Printf.sprintf "field %S must be a list" name)

let all f l =
  List.fold_right
    (fun x acc ->
      let* acc = acc in
      let* y = f x in
      Ok (y :: acc))
    l (Ok [])

let parse_json what bytes =
  match Yojson.Safe.from_string bytes with
  | json -> Ok json
  | exception Yojson.Json_error e ->
      Error (Printf.sprintf "%s is not JSON: %s" what e)

let expect_format want json =
  let* got = string_field "format" json in
  if got = want then Ok ()
  else Error (Printf.sprintf "format %S, expected %S" got want)

let signer_of_json json =
  let* name = string_field "name" json in
  let* key = string_field "key" json in
  let* key = Crypto.public_key_of_string key in
  Ok { name; key }

let signer_to_json s =
  `Assoc [ ("name", `String s.name); ("key", `String s.key) ]

let artifact_of_json json =
  let* platform = string_field "platform" json in
  let* url = string_field "url" json in
  let* sha256 = string_field "sha256" json in
  let* size = int_field "size" json in
  let hex = String.length Crypto.hash_prefix in
  if
    String.length sha256 <> hex + 64
    || String.sub sha256 0 hex <> Crypto.hash_prefix
    || not
         (String.for_all
            (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
            (String.sub sha256 hex 64))
  then
    Error
      (Printf.sprintf "artifact %s: sha256 must be sha256:<64 lowercase hex>"
         platform)
  else Ok { platform; url; sha256; size }

let manifest_of_string bytes =
  let* json = parse_json "manifest" bytes in
  let* () = expect_format manifest_format json in
  let* version = string_field "version" json in
  let* version = Version.of_string version in
  let* published_at = string_field "published_at" json in
  let* notes = optional_string "notes" json in
  let* artifacts = list_field "artifacts" json in
  let* artifacts = all artifact_of_json artifacts in
  let* signers =
    match field "signers" json with
    | None | Some `Null -> Ok None
    | Some (`List l) ->
        let* l = all signer_of_json l in
        Ok (Some l)
    | Some _ -> Error "field \"signers\" must be a list"
  in
  Ok { version; published_at; notes; artifacts; signers }

let revocation_of_string bytes =
  let* json = parse_json "revocation" bytes in
  let* () = expect_format revocation_format json in
  let* key = string_field "key" json in
  let* key = Crypto.public_key_of_string key in
  let* reason = optional_string "reason" json in
  let* revoked_at = string_field "revoked_at" json in
  Ok { revoked_key = key; reason; revoked_at }

let signatures_of_string bytes =
  let* json = parse_json "signatures" bytes in
  let* l = list_field "signatures" json in
  all
    (fun s ->
      let* by = string_field "key" s in
      let* by = Crypto.public_key_of_string by in
      let* signature = string_field "signature" s in
      Ok { by; signature })
    l

let signatures_to_string sigs =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ( "signatures",
           `List
             (List.map
                (fun s ->
                  `Assoc
                    [
                      ("key", `String s.by); ("signature", `String s.signature);
                    ])
                sigs) );
       ])
  ^ "\n"

let signed_bytes ~domain bytes = domain ^ bytes

(* The keys among [sigs] whose signature over [bytes] verifies, each counted once. *)
let valid_signers ~domain bytes sigs =
  let msg = signed_bytes ~domain bytes in
  List.fold_left
    (fun acc s ->
      if List.mem s.by acc then acc
      else if Crypto.verify s.by ~signature:s.signature msg then s.by :: acc
      else acc)
    [] sigs

(* Add (or replace) [secret]'s signature over [bytes] in [sigs]. *)
let add_signature ~domain ~secret bytes sigs =
  let by = Crypto.public_key_of_secret secret in
  let signature = Crypto.sign secret (signed_bytes ~domain bytes) in
  List.filter (fun s -> s.by <> by) sigs @ [ { by; signature } ]
