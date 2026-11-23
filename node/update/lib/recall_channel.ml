(* A signer's half of a recall (docs/releases.md, A recall): put the recall into checkouts of the
   channel. `digestif-update recall` commits what this writes to release/ on main and to the
   `channel` branch with the signer's own `gh` login, and posts the same document on the circle
   (Circle_recall).

   recalls/<version>.json is written once and never edited, since a signature is over its exact
   bytes: the second signer recalling the same version signs those bytes, whatever reason they
   gave, and their signature joins the first in recalls/<version>.sig.json (Takeback). *)

open Release

let ( let* ) = Result.bind
let document_path v = "recalls/" ^ Version.to_string v ^ ".json"
let signatures_path v = "recalls/" ^ Version.to_string v ^ ".sig.json"

let entry v =
  `Assoc
    [
      ("version", `String (Version.to_string v));
      ("document", `String (document_path v));
      ("signatures", `String (signatures_path v));
    ]

(* The index with [v]'s recall listed, or unchanged when it is already. Every other field of the
   index is kept as it is. *)
let index_with_recall json v = Takeback.index_with json ~list:"recalls" ~entry:(entry v)

(* Whether the channel checked out at [dir] lists [version]. *)
let lists ~dir version =
  let* index_bytes = Takeback.read (Filename.concat dir "index.json") in
  let* index = Feed.index_of_string index_bytes in
  Ok
    (List.exists
       (fun (e : Feed.entry) ->
         match Option.map Version.of_string e.version with
         | Some (Ok w) -> Version.equal w version
         | _ -> false)
       index.releases)

type written = {
  recall : recall signed;
  first : bool;  (** This call wrote the document; otherwise it signed one. *)
}

(* Recall [version] in every checkout of [dirs] that lists it, signed with [secret]. A recall names
   a release members can have, so one checkout at least must list the version; a checkout whose
   list no longer names it takes no recall, since a recall goes with its version's list entry. *)
let write_recalls ~dirs ~secret ~version ~reason ~recalled_at =
  let* listing =
    List.fold_left
      (fun acc dir ->
        let* acc = acc in
        let* l = lists ~dir version in
        Ok (if l then acc @ [ dir ] else acc))
      (Ok []) dirs
  in
  match listing with
  | [] ->
      Error
        (Printf.sprintf
           "the channel publishes no release %s, so there is nothing to recall"
           (Version.to_string version))
  | dirs ->
      let* w =
        Takeback.write ~dirs ~document:(document_path version)
          ~signatures:(signatures_path version) ~list:"recalls"
          ~entry:(entry version)
          ~fresh:(fun () ->
            recall_to_string { recalled_version = version; reason; recalled_at })
          ~parse:recall_of_string
          ~check:(fun doc ->
            if Version.equal doc.recalled_version version then Ok ()
            else Error (document_path version ^ " recalls another version"))
          ~domain:recall_domain ~secret
      in
      Ok { recall = w.signed; first = w.first }

(* Recall [version] in the channel checked out at [dir]. *)
let write_recall ~dir ~secret ~version ~reason ~recalled_at =
  write_recalls ~dirs:[ dir ] ~secret ~version ~reason ~recalled_at
