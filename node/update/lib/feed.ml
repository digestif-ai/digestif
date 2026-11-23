(* The release channel: an index naming every release, revocation, recall and signer-set change, each document beside its
   detached signatures. The index is unsigned and trusted for nothing: everything it points at is
   verified, so a channel that lies can only withhold, which halts updates exactly as a signer who
   will not sign does. *)

open Release

let ( let* ) = Result.bind

(* Reads an absolute https URL or a local path, refusing an answer longer than [limit] bytes. *)
type fetch = limit:int -> string -> (string, string) result

(* The most any channel document (the index, a manifest, a revocation, a recall, a signer-set
   change, a signature file) may hold. The index names what a node reads and is signed by nobody, so
   every read is bounded: a channel that lists an endless answer is refused at this many bytes, not
   read until memory runs out. An archive is bounded by the size its signed manifest states. *)
let document_limit = 1_048_576

(* The channel every node reads unless told another: release/ on main (docs/releases.md, The
   channel). *)
let default_url =
  "https://raw.githubusercontent.com/digestif-ai/digestif/main/release/"

let is_https u = String.length u > 8 && String.sub u 0 8 = "https://"
let is_http u = String.length u > 7 && String.sub u 0 7 = "http://"

(* Where an index entry [rel] lives. Under an https channel only another https URL or a path relative
   to the channel resolves: an absolute path would have every node read its own disk (a device that
   never ends, a file that is not the channel's) at the say of an index nobody signs. A channel on
   disk is the operator's own, and keeps both. *)
let resolve ~base rel =
  if is_https rel then Ok rel
  else if String.length rel > 0 && rel.[0] = '/' then
    if is_https base then
      Error (Printf.sprintf "%s: an https channel names no local path" rel)
    else Ok rel
  else if String.length base > 0 && base.[String.length base - 1] = '/' then
    Ok (base ^ rel)
  else Ok (base ^ "/" ^ rel)

(* At most [limit] bytes of [ic], or None when it holds more. *)
let input_bounded ic ~limit =
  let buf = Buffer.create (min limit 65_536) in
  let chunk = Bytes.create 65_536 in
  let rec loop () =
    if Buffer.length buf > limit then None
    else
      match In_channel.input ic chunk 0 (Bytes.length chunk) with
      | 0 -> Some (Buffer.contents buf)
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          loop ()
  in
  loop ()

let too_long target limit =
  Printf.sprintf "%s: longer than the %d bytes the channel allows it" target
    limit

(* What curl's commonest exit codes mean, so a digest line names the cause rather than a number. *)
let curl_cause = function
  | 6 -> Some "the host name did not resolve: no network or no DNS"
  | 7 -> Some "the server could not be reached"
  | 22 -> Some "the server answered with an error"
  | 28 -> Some "it timed out"
  | 35 -> Some "the TLS handshake failed"
  | 52 | 56 -> Some "the connection broke"
  | 60 -> Some "the server's certificate was not trusted"
  | 63 -> Some "the answer was larger than the channel allows"
  | _ -> None

let curl ~limit url =
  let argv =
    [|
      "curl";
      "--fail";
      "--silent";
      "--show-error";
      "--location";
      "--proto";
      "=https";
      (* A release download may take minutes on a slow link, so the whole fetch gets ten; a channel
         that never connects, or a transfer that stalls, ends long before that. *)
      "--connect-timeout";
      "30";
      "--speed-limit";
      "1024";
      "--speed-time";
      "60";
      "--max-time";
      "600";
      "--max-filesize";
      string_of_int limit;
      url;
    |]
  in
  let ic = Unix.open_process_args_in "curl" argv in
  (* --max-filesize stops an answer that declares its length; the bounded read stops one that does
     not, and closing the pipe ends curl on its next write. *)
  let body = input_bounded ic ~limit in
  match (Unix.close_process_in ic, body) with
  | _, None -> Error (too_long url limit)
  | Unix.WEXITED 0, Some body -> Ok body
  | Unix.WEXITED n, Some _ -> (
      match curl_cause n with
      | Some cause ->
          Error (Printf.sprintf "%s: curl exited %d (%s)" url n cause)
      | None -> Error (Printf.sprintf "%s: curl exited %d" url n))
  | _ -> Error (url ^ ": curl was killed")

(* The fetch a node uses: https through curl, which every Mac and Linux machine carries, and local
   paths for a channel on disk. Plain http is refused. Every read stops at [limit] bytes. *)
let default_fetch : fetch =
 fun ~limit target ->
  if is_https target then curl ~limit target
  else if is_http target then
    Error (target ^ ": the release channel is https only")
  else
    match In_channel.with_open_bin target (input_bounded ~limit) with
    | Some s -> Ok s
    | None -> Error (too_long target limit)
    | exception Sys_error e -> Error e

(* Whether the channel answers at all: any HTTP answer, an error status included, means this machine
   reached it. The sync asks it when every relay failed, to tell this machine being offline from the
   relays being down (ISS-65273). A channel on disk says nothing about the network, so it counts as
   reached and the relays keep the blame. *)
let reachable ?(max_time = 20) target =
  if not (is_https target) then true
  else
    let argv =
      [|
        "curl";
        "--silent";
        "--head";
        "--output";
        "/dev/null";
        "--proto";
        "=https";
        "--max-time";
        string_of_int max_time;
        target;
      |]
    in
    match Unix.open_process_args_in "curl" argv with
    | exception Unix.Unix_error _ -> true
    | ic -> (
        ignore (In_channel.input_all ic);
        match Unix.close_process_in ic with
        | Unix.WEXITED 0 -> true
        | _ -> false)

type entry = { version : string option; document : string; signatures : string }

type index = {
  releases : entry list;
  revocations : entry list;
  recalls : entry list;
  signers : entry list;
}

let entry_of_json ~doc_field json =
  let* document = string_field doc_field json in
  let* signatures = string_field "signatures" json in
  let version =
    match field "version" json with Some (`String v) -> Some v | _ -> None
  in
  Ok { version; document; signatures }

let index_of_string bytes =
  let* json = parse_json "index" bytes in
  let* () = expect_format "digestif-feed-v0" json in
  let* releases = list_field "releases" json in
  let* releases = all (entry_of_json ~doc_field:"manifest") releases in
  let* revocations =
    match field "revocations" json with
    | None -> Ok []
    | Some _ ->
        let* l = list_field "revocations" json in
        all (entry_of_json ~doc_field:"document") l
  in
  let* recalls =
    match field "recalls" json with
    | None -> Ok []
    | Some _ ->
        let* l = list_field "recalls" json in
        all (entry_of_json ~doc_field:"document") l
  in
  let* signers =
    match field "signers" json with
    | None -> Ok []
    | Some _ ->
        let* l = list_field "signers" json in
        all (entry_of_json ~doc_field:"document") l
  in
  Ok { releases; revocations; recalls; signers }

let fetch_document (fetch : fetch) ~base rel =
  let* target = resolve ~base rel in
  fetch ~limit:document_limit target

let fetch_signed (fetch : fetch) ~base parse e =
  let* bytes = fetch_document fetch ~base e.document in
  let* doc = parse bytes in
  let* sigs = fetch_document fetch ~base e.signatures in
  let* signatures = signatures_of_string sigs in
  Ok { bytes; doc; signatures }

type t = {
  releases : manifest signed list;
  revocations : revocation signed list;
  recalls : recall signed list;
      (** Every recall the channel holds, whoever signed it: what counts is
          decided against the node's own signer set (Recall). *)
  signer_sets : signer_set signed list;
      (** Every signer-set change under signers/, in the index's order: each is
          adopted only when it verifies against the set the node holds
          (Policy.adopt_sets). *)
  problems : string list;
      (** Entries that could not be fetched or parsed, skipped. *)
}

(* Every revocation, recall and signer-set change, and every release the index says is newer than [installed]. An entry that
   cannot be read is a problem to report, never a reason to stop reading the rest. *)
let read (fetch : fetch) ~base ~installed =
  let* bytes = fetch_document fetch ~base "index.json" in
  let* index = index_of_string bytes in
  let newer e =
    match e.version with
    | None -> true
    | Some v -> (
        match Version.of_string v with
        | Ok v -> Version.compare v installed > 0
        | Error _ -> true)
  in
  let gather parse entries =
    List.fold_left
      (fun (ok, bad) e ->
        match fetch_signed fetch ~base parse e with
        | Ok s -> (s :: ok, bad)
        | Error why -> (ok, (e.document ^ ": " ^ why) :: bad))
      ([], []) entries
  in
  let releases, bad_releases =
    gather manifest_of_string (List.filter newer index.releases)
  in
  let revocations, bad_revocations =
    gather revocation_of_string index.revocations
  in
  let recalls, bad_recalls = gather recall_of_string index.recalls in
  let signer_sets, bad_sets = gather signer_set_of_string index.signers in
  Ok
    {
      releases = List.rev releases;
      revocations = List.rev revocations;
      recalls = List.rev recalls;
      signer_sets = List.rev signer_sets;
      problems =
        List.rev_append bad_revocations
          (List.rev_append bad_recalls
             (List.rev_append bad_sets (List.rev bad_releases)));
    }
