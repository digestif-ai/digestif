(* A signer's half of a recall (docs/releases.md, A recall): put the recall into a checkout of the
   channel. `digestif-update recall` commits what this writes to the `channel` branch with the
   signer's own `gh` login and posts the same document on the circle (Circle_recall).

   recalls/<version>.json is written once and never edited, since a signature is over its exact
   bytes: the second signer recalling the same version signs those bytes, whatever reason they
   gave, and their signature joins the first in recalls/<version>.sig.json. *)

open Release

let ( let* ) = Result.bind
let document_path v = "recalls/" ^ Version.to_string v ^ ".json"
let signatures_path v = "recalls/" ^ Version.to_string v ^ ".sig.json"

let read path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> Ok s
  | exception Sys_error e -> Error e

let write path contents =
  State.mkdir_p (Filename.dirname path);
  State.write_atomic path contents

(* The index with [v]'s recall listed, or unchanged when it is already. Every other field of the
   index is kept as it is. *)
let index_with_recall json v =
  let entry =
    `Assoc
      [
        ("version", `String (Version.to_string v));
        ("document", `String (document_path v));
        ("signatures", `String (signatures_path v));
      ]
  in
  match json with
  | `Assoc fields ->
      let existing =
        match List.assoc_opt "recalls" fields with
        | Some (`List l) -> l
        | _ -> []
      in
      let listed =
        List.exists
          (fun e -> field "document" e = Some (`String (document_path v)))
          existing
      in
      if listed then Ok json
      else
        Ok
          (`Assoc
             (List.remove_assoc "recalls" fields
             @ [ ("recalls", `List (existing @ [ entry ])) ]))
  | _ -> Error "index.json is not an object"

type written = {
  recall : recall signed;
  first : bool;  (** This call wrote the document; otherwise it signed one. *)
}

(* Recall [version] in the channel checked out at [dir], signed with [secret]. The channel must
   publish the version: a recall names a release members can have. *)
let write_recall ~dir ~secret ~version ~reason ~recalled_at =
  let at rel = Filename.concat dir rel in
  let* index_bytes = read (at "index.json") in
  let* index = Feed.index_of_string index_bytes in
  let published =
    List.exists
      (fun (e : Feed.entry) ->
        match Option.map Version.of_string e.version with
        | Some (Ok w) -> Version.equal w version
        | _ -> false)
      index.releases
  in
  if not published then
    Error
      (Printf.sprintf
         "the channel publishes no release %s, so there is nothing to recall"
         (Version.to_string version))
  else
    let doc_file = at (document_path version) in
    let sig_file = at (signatures_path version) in
    let* bytes, first =
      if Sys.file_exists doc_file then
        let* bytes = read doc_file in
        let* doc = recall_of_string bytes in
        if Version.equal doc.recalled_version version then Ok (bytes, false)
        else Error (doc_file ^ " recalls another version")
      else
        Ok
          ( recall_to_string { recalled_version = version; reason; recalled_at },
            true )
    in
    let* doc = recall_of_string bytes in
    let* sigs =
      if Sys.file_exists sig_file then
        let* s = read sig_file in
        signatures_of_string s
      else Ok []
    in
    let signatures = add_signature ~domain:recall_domain ~secret bytes sigs in
    let* json = parse_json "index" index_bytes in
    let* json = index_with_recall json version in
    if first then write doc_file bytes;
    write sig_file (signatures_to_string signatures);
    write (at "index.json") (Yojson.Safe.pretty_to_string json ^ "\n");
    Ok { recall = { bytes; doc; signatures }; first }
