(* The signed documents of the release channel (docs/releases.md): a release manifest, a key
   revocation, and the detached signatures over either. A signature is over a domain prefix plus the
   document's exact bytes as published, so no canonical encoding is involved and a byte that changes
   after signing breaks every signature. *)

type signer = { name : string; key : Keys.public_key }
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
  revoked_key : Keys.public_key;
  reason : string;
  revoked_at : string;
}

(* One signer's statement that a published version is bad (docs/releases.md, A recall). *)
type recall = {
  recalled_version : Version.t;
  reason : string;
  recalled_at : string;
}

(* One version of the relay: its Worker, its phone app and its D1 migrations, packed as one bundle
   on a version line of its own (docs/releases.md, Relay releases). The same signer set signs it,
   over its own domain line, so a relay signature is never a node release, a revocation or a
   recall. *)
type relay_bundle = {
  bundle_url : string;
  bundle_sha256 : string;
  bundle_size : int;
}

type relay_migration = { migration : string; migration_sha256 : string }

type relay_manifest = {
  relay_version : Version.t;
  relay_published_at : string;
  relay_notes : string;
  bundle : relay_bundle;
  migrations : relay_migration list;
      (** Every migration from the first, in the order they apply. *)
  compatible_with : Version.t;
      (** The oldest relay version this one is wire-compatible with. *)
}

type signature = { by : Keys.public_key; signature : string }

(* A document as fetched: its exact bytes, parsed, and the signatures published beside it. *)
type 'a signed = { bytes : string; doc : 'a; signatures : signature list }

let release_domain = "DIGESTIF-RELEASE-V0\n"
let revocation_domain = "DIGESTIF-REVOCATION-V0\n"
let recall_domain = "DIGESTIF-RECALL-V0\n"
let manifest_format = "digestif-release-v1"
let revocation_format = "digestif-revocation-v0"
let recall_format = "digestif-recall-v0"
let relay_release_domain = "DIGESTIF-RELAY-RELEASE-V0\n"
let relay_manifest_format = "digestif-relay-release-v1"
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
  let* key = Keys.parse_ed25519 key in
  Ok { name; key }

let signer_to_json s =
  `Assoc [ ("name", `String s.name); ("key", `String s.key) ]

(* A digest as every signed document writes one: sha256:<64 lowercase hex>. *)
let is_sha256 sha256 =
  let hex = String.length Keys.sha256_prefix in
  String.length sha256 = hex + 64
  && String.sub sha256 0 hex = Keys.sha256_prefix
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub sha256 hex 64)

let artifact_of_json json =
  let* platform = string_field "platform" json in
  let* url = string_field "url" json in
  let* sha256 = string_field "sha256" json in
  let* size = int_field "size" json in
  if not (is_sha256 sha256) then
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
  let* key = Keys.parse_ed25519 key in
  let* reason = optional_string "reason" json in
  let* revoked_at = string_field "revoked_at" json in
  Ok { revoked_key = key; reason; revoked_at }

let recall_of_string bytes =
  let* json = parse_json "recall" bytes in
  let* () = expect_format recall_format json in
  let* version = string_field "version" json in
  let* recalled_version = Version.of_string version in
  let* reason = string_field "reason" json in
  let* recalled_at = string_field "recalled_at" json in
  Ok { recalled_version; reason; recalled_at }

(* A recall document's bytes, as `digestif-update recall` writes it; nobody edits it after. *)
let recall_to_string r =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String recall_format);
         ("version", `String (Version.to_string r.recalled_version));
         ("reason", `String r.reason);
         ("recalled_at", `String r.recalled_at);
       ])
  ^ "\n"

(* A migration's file name: NNNN_<lowercase words>.sql, as relay/migrations names them, so the
   name alone orders them and none names a path. *)
let is_migration_name name =
  let n = String.length name in
  n > 9
  && String.for_all
       (function '0' .. '9' -> true | _ -> false)
       (String.sub name 0 4)
  && name.[4] = '_'
  && String.ends_with ~suffix:".sql" name
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
       (String.sub name 5 (n - 9))

let migration_of_json json =
  let* migration = string_field "name" json in
  let* migration_sha256 = string_field "sha256" json in
  if not (is_migration_name migration) then
    Error
      (Printf.sprintf "migration %S: a name is NNNN_<lowercase words>.sql"
         migration)
  else if not (is_sha256 migration_sha256) then
    Error
      (Printf.sprintf "migration %s: sha256 must be sha256:<64 lowercase hex>"
         migration)
  else Ok { migration; migration_sha256 }

(* The migrations in the order they apply: strictly ascending by name, each named once. *)
let check_migration_order migrations =
  let rec go = function
    | a :: (b :: _ as rest) ->
        if String.compare a.migration b.migration < 0 then go rest
        else
          Error
            (Printf.sprintf "migration %s is listed after %s" b.migration
               a.migration)
    | _ -> Ok ()
  in
  go migrations

let relay_manifest_of_string bytes =
  let* json = parse_json "relay manifest" bytes in
  let* () = expect_format relay_manifest_format json in
  let* version = string_field "version" json in
  let* relay_version = Version.of_string version in
  let* relay_published_at = string_field "published_at" json in
  let* relay_notes = optional_string "notes" json in
  let* bundle =
    match field "bundle" json with
    | Some (`Assoc _ as b) ->
        let* bundle_url = string_field "url" b in
        let* bundle_sha256 = string_field "sha256" b in
        let* bundle_size = int_field "size" b in
        if not (is_sha256 bundle_sha256) then
          Error "bundle: sha256 must be sha256:<64 lowercase hex>"
        else Ok { bundle_url; bundle_sha256; bundle_size }
    | _ -> Error "field \"bundle\" must be an object"
  in
  let* migrations = list_field "migrations" json in
  let* migrations = all migration_of_json migrations in
  let* () = check_migration_order migrations in
  let* compatible = string_field "compatible_with" json in
  let* compatible_with = Version.of_string compatible in
  if Version.compare compatible_with relay_version > 0 then
    Error
      (Printf.sprintf "compatible_with %s is newer than the version %s"
         compatible
         (Version.to_string relay_version))
  else
    Ok
      {
        relay_version;
        relay_published_at;
        relay_notes;
        bundle;
        migrations;
        compatible_with;
      }

(* A relay manifest's bytes, as `digestif-update relay-manifest` writes it; nobody edits it after,
   since every signature is over these bytes. *)
let relay_manifest_to_string m =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String relay_manifest_format);
         ("version", `String (Version.to_string m.relay_version));
         ("published_at", `String m.relay_published_at);
         ("notes", `String m.relay_notes);
         ( "bundle",
           `Assoc
             [
               ("url", `String m.bundle.bundle_url);
               ("sha256", `String m.bundle.bundle_sha256);
               ("size", `Int m.bundle.bundle_size);
             ] );
         ( "migrations",
           `List
             (List.map
                (fun g ->
                  `Assoc
                    [
                      ("name", `String g.migration);
                      ("sha256", `String g.migration_sha256);
                    ])
                m.migrations) );
         ("compatible_with", `String (Version.to_string m.compatible_with));
       ])
  ^ "\n"

(* Which document [bytes] is, read from its format field alone. *)
type document_kind = Node_release | Relay_release | Other of string

let document_kind bytes =
  match parse_json "document" bytes with
  | Error e -> Error e
  | Ok json -> (
      match string_field "format" json with
      | Error e -> Error e
      | Ok f when f = manifest_format -> Ok Node_release
      | Ok f when f = relay_manifest_format -> Ok Relay_release
      | Ok f -> Ok (Other f))

let signatures_of_string bytes =
  let* json = parse_json "signatures" bytes in
  let* l = list_field "signatures" json in
  all
    (fun s ->
      let* by = string_field "key" s in
      let* by = Keys.parse_ed25519 by in
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
      else if Keys.verify ~pub:s.by ~signature:s.signature msg then s.by :: acc
      else acc)
    [] sigs

(* Add (or replace) [secret]'s signature over [bytes] in [sigs]. *)
let add_signature ~domain ~secret bytes sigs =
  let by = Keys.public secret in
  let signature = Keys.sign secret (signed_bytes ~domain bytes) in
  List.filter (fun s -> s.by <> by) sigs @ [ { by; signature } ]

(* A signed document as a circle message carries it (docs/protocol.md, release_revocation and
   release_recall): the document's exact bytes in base64url, since a signature is over those bytes
   and JCS would re-encode a JSON object, and the signatures from its .sig.json. *)
let body_of_signed (s : _ signed) : Yojson.Safe.t =
  `Assoc
    [
      ("document", `String (B64url.encode s.bytes));
      ( "signatures",
        `List
          (List.map
             (fun s ->
               `Assoc
                 [ ("key", `String s.by); ("signature", `String s.signature) ])
             s.signatures) );
    ]

(* The document a circle body carries, parsed with [parse], and its signatures read but not yet
   checked against any signer set. *)
let signed_of_body parse (json : Yojson.Safe.t) =
  let* encoded = string_field "document" json in
  let* bytes =
    Result.map_error
      (fun e -> "field \"document\" is not base64url: " ^ e)
      (B64url.decode encoded)
  in
  let* doc = parse bytes in
  let* signatures = list_field "signatures" json in
  let* signatures =
    all
      (fun s ->
        let* by = string_field "key" s in
        let* by = Keys.parse_ed25519 by in
        let* signature = string_field "signature" s in
        Ok { by; signature })
      signatures
  in
  Ok { bytes; doc; signatures }
