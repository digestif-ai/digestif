(* The release channel: an index naming every release and revocation, each document beside its
   detached signatures. The index is unsigned and trusted for nothing: everything it points at is
   verified, so a channel that lies can only withhold, which halts updates exactly as a signer who
   will not sign does. *)

open Release

let ( let* ) = Result.bind

(* Reads an absolute https URL or a local path. *)
type fetch = string -> (string, string) result

let default_url =
  "https://raw.githubusercontent.com/digestif-ai/digestif/main/releases/"

let is_https u = String.length u > 8 && String.sub u 0 8 = "https://"
let is_http u = String.length u > 7 && String.sub u 0 7 = "http://"

let resolve ~base rel =
  if is_https rel || (String.length rel > 0 && rel.[0] = '/') then rel
  else if String.length base > 0 && base.[String.length base - 1] = '/' then
    base ^ rel
  else base ^ "/" ^ rel

let curl url =
  let argv =
    [|
      "curl";
      "--fail";
      "--silent";
      "--show-error";
      "--location";
      "--proto";
      "=https";
      "--max-time";
      "600";
      url;
    |]
  in
  let ic = Unix.open_process_args_in "curl" argv in
  let body = In_channel.input_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Ok body
  | Unix.WEXITED n -> Error (Printf.sprintf "%s: curl exited %d" url n)
  | _ -> Error (url ^ ": curl was killed")

(* The fetch a node uses: https through curl, which every Mac and Linux machine carries, and local
   paths for a channel on disk. Plain http is refused. *)
let default_fetch : fetch =
 fun target ->
  if is_https target then curl target
  else if is_http target then
    Error (target ^ ": the release channel is https only")
  else
    match In_channel.with_open_bin target In_channel.input_all with
    | s -> Ok s
    | exception Sys_error e -> Error e

type entry = { version : string option; document : string; signatures : string }
type index = { releases : entry list; revocations : entry list }

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
  Ok { releases; revocations }

let fetch_signed (fetch : fetch) ~base parse e =
  let* bytes = fetch (resolve ~base e.document) in
  let* doc = parse bytes in
  let* sigs = fetch (resolve ~base e.signatures) in
  let* signatures = signatures_of_string sigs in
  Ok { bytes; doc; signatures }

type t = {
  releases : manifest signed list;
  revocations : revocation signed list;
  problems : string list;
      (** Entries that could not be fetched or parsed, skipped. *)
}

(* Every revocation, and every release the index says is newer than [installed]. An entry that
   cannot be read is a problem to report, never a reason to stop reading the rest. *)
let read (fetch : fetch) ~base ~installed =
  let* bytes = fetch (resolve ~base "index.json") in
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
  Ok
    {
      releases = List.rev releases;
      revocations = List.rev revocations;
      problems = List.rev_append bad_revocations (List.rev bad_releases);
    }
