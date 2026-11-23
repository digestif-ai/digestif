(* A take-back a signer writes into the channel (docs/releases.md, The channel): a recall or a
   revocation, one signed document beside its signatures, listed in index.json. The channel has two
   addresses while the `channel` branch is readable, release/ on main and the branch's root, and a
   take-back goes to every checkout it is handed, as one document: the bytes the first signer wrote,
   wherever they already are, with every signature any address holds and this signer's added.

   <document> is written once and never edited, since a signature is over its exact bytes: a second
   signer signs those bytes, and their signature joins the first in <signatures>. *)

open Release

let ( let* ) = Result.bind

let read path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> Ok s
  | exception Sys_error e -> Error e

let write path contents =
  State.mkdir_p (Filename.dirname path);
  State.write_atomic path contents

(* The index with [entry] listed under [list], or unchanged when an entry already names the same
   document. Every other field of the index is kept as it is. *)
let index_with json ~list ~(entry : Yojson.Safe.t) =
  let document = field "document" entry in
  match json with
  | `Assoc fields ->
      let existing =
        match List.assoc_opt list fields with Some (`List l) -> l | _ -> []
      in
      if List.exists (fun e -> field "document" e = document) existing then
        Ok json
      else
        Ok
          (`Assoc
             (List.remove_assoc list fields
             @ [ (list, `List (existing @ [ entry ])) ]))
  | _ -> Error "index.json is not an object"

(* Every signature of [a], then each of [b] by a key [a] has none from. *)
let union a b =
  a @ List.filter (fun s -> not (List.exists (fun t -> t.by = s.by) a)) b

(* The document the checkouts already hold, and every signature beside it in any of them. Two
   addresses holding different bytes under the same name is refused: no signature could be over
   both. *)
let held ~dirs ~document ~signatures =
  List.fold_left
    (fun acc dir ->
      let* bytes, sigs = acc in
      let doc_file = Filename.concat dir document in
      if not (Sys.file_exists doc_file) then Ok (bytes, sigs)
      else
        let* b = read doc_file in
        let* () =
          match bytes with
          | Some other when other <> b ->
              Error
                (Printf.sprintf
                   "%s differs between the channel's addresses; nothing was \
                    written"
                   document)
          | _ -> Ok ()
        in
        let sig_file = Filename.concat dir signatures in
        let* more =
          if Sys.file_exists sig_file then
            let* s = read sig_file in
            signatures_of_string s
          else Ok []
        in
        Ok (Some b, union sigs more))
    (Ok (None, []))
    dirs

type 'a written = {
  signed : 'a signed;
  first : bool;  (** This call wrote the document; otherwise it signed one. *)
}

(* Write the take-back into every checkout of [dirs] and list it under [list] in each one's
   index.json: the document already held, else [fresh ()], checked by [parse] and [check], signed
   with [secret] over [domain]. *)
let write ~dirs ~document ~signatures ~list ~(entry : Yojson.Safe.t) ~fresh
    ~parse ~check ~domain ~secret =
  let* held_bytes, held_sigs = held ~dirs ~document ~signatures in
  let bytes, first =
    match held_bytes with Some b -> (b, false) | None -> (fresh (), true)
  in
  let* doc = parse bytes in
  let* () = check doc in
  let sigs = add_signature ~domain ~secret bytes held_sigs in
  let* indexes =
    all
      (fun dir ->
        let at = Filename.concat dir in
        let* index_bytes = read (at "index.json") in
        let* json = parse_json "index" index_bytes in
        let* json = index_with json ~list ~entry in
        Ok (dir, json))
      dirs
  in
  List.iter
    (fun (dir, json) ->
      let at = Filename.concat dir in
      if not (Sys.file_exists (at document)) then write (at document) bytes;
      write (at signatures) (signatures_to_string sigs);
      write (at "index.json") (Yojson.Safe.pretty_to_string json ^ "\n"))
    indexes;
  Ok { signed = { bytes; doc; signatures = sigs }; first }
