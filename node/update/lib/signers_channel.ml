(* The channel's signers/ (docs/releases.md, The channel): every signer-set change, the document's
   exact bytes beside its signatures, listed under "signers" in index.json. `digestif-update sign
   --next` writes what this puts into a checkout of the channel before it signs a version, with the
   signer's own `gh` login, so the channel and `ci/release.sh`'s check hold the new set before the
   next release ships: a version cannot reach candidate/ until every admin, the new one included,
   has signed it.

   signers/<name>.json is written once and never edited, since a signature is over its exact bytes;
   <name> is the first 16 hex digits of its sha256, so the same change is one file whoever writes
   it. *)

open Release

let ( let* ) = Result.bind

let name (s : signer_set signed) =
  let h = Keys.hash_of_bytes s.bytes in
  let hex = String.length Keys.sha256_prefix in
  String.sub h hex 16

let document_path s = "signers/" ^ name s ^ ".json"
let signatures_path s = "signers/" ^ name s ^ ".sig.json"

let read path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> Ok s
  | exception Sys_error e -> Error e

let write path contents =
  State.mkdir_p (Filename.dirname path);
  State.write_atomic path contents

(* The changes of [held] the channel at [dir] does not list yet, oldest first. *)
let missing ~dir (held : signer_set signed list) =
  let* index_bytes = read (Filename.concat dir "index.json") in
  let* index = Feed.index_of_string index_bytes in
  let listed = List.map (fun (e : Feed.entry) -> e.document) index.signers in
  Ok (List.filter (fun s -> not (List.mem (document_path s) listed)) held)

(* The index with [s] listed under "signers", every other field kept as it is. *)
let index_with json s =
  let entry =
    `Assoc
      [
        ("document", `String (document_path s));
        ("signatures", `String (signatures_path s));
      ]
  in
  match json with
  | `Assoc fields ->
      let existing =
        match List.assoc_opt "signers" fields with
        | Some (`List l) -> l
        | _ -> []
      in
      Ok
        (`Assoc
           (List.remove_assoc "signers" fields
           @ [ ("signers", `List (existing @ [ entry ])) ]))
  | _ -> Error "index.json is not an object"

(* Write every change of [held] the channel checked out at [dir] lacks. Answers the changes
   written; none when the channel already lists every one. *)
let write_sets ~dir (held : signer_set signed list) =
  let* sets = missing ~dir held in
  match sets with
  | [] -> Ok []
  | _ ->
      let at rel = Filename.concat dir rel in
      let* index_bytes = read (at "index.json") in
      let* json = parse_json "index" index_bytes in
      let* json =
        List.fold_left
          (fun acc s ->
            let* j = acc in
            index_with j s)
          (Ok json) sets
      in
      List.iter
        (fun s ->
          write (at (document_path s)) s.bytes;
          write (at (signatures_path s)) (signatures_to_string s.signatures))
        sets;
      write (at "index.json") (Yojson.Safe.pretty_to_string json ^ "\n");
      Ok sets

(* The set a signer signs under: the build's, advanced by every change the channel lists and every
   change the node on this machine holds, each checked against the set before it. A promoted admin's
   key is in it from the moment the change is signed, before any release carries it. *)
let current ~build ~(channel : Feed.t option) ~(held : signer_set signed list) =
  let revocations, from_channel =
    match channel with
    | Some f -> (f.revocations, f.signer_sets)
    | None -> ([], [])
  in
  let a =
    Policy.adopt_sets
      { signers = build; revoked = [] }
      ~revocations (from_channel @ held)
  in
  a.adopted_trust.signers
