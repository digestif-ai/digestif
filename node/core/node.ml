(* One node: its data directory, its log and its keystore, and the acts that need all three. *)

type t = { dir : string; log : Log.t; keystore : Keystore.t }

let default_dir () =
  match Sys.getenv_opt "DIGESTIF_HOME" with
  | Some d when d <> "" -> d
  | _ ->
      let home = Option.value (Sys.getenv_opt "HOME") ~default:"." in
      if Keystore.is_macos () then
        Filename.concat home "Library/Application Support/Digestif"
      else
        let data =
          match Sys.getenv_opt "XDG_DATA_HOME" with
          | Some d when d <> "" -> d
          | _ -> Filename.concat home ".local/share"
        in
        Filename.concat data "digestif"

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let open_ ?keystore dir =
  mkdir_p dir;
  let keystore =
    match keystore with Some k -> k | None -> Keystore.default ~scope:dir
  in
  { dir; log = Log.open_ (Filename.concat dir "log.sqlite3"); keystore }

let close t = Log.close t.log

(* Config keys. *)
let k_root = "root"
let k_identity = "identity_key"
let k_device = "device_key"
let k_mail = "mail_key"
let k_encryption = "encryption_key"
let root t = Log.get_config t.log k_root
let set_root t h = Log.set_config t.log k_root h
let ( let* ) = Result.bind

(* Create this machine's device and mail keys, cache the encryption key, and record the public halves.
   The phrase is read, used and dropped here; nothing derived from it but the encryption key is kept. *)
let init t ~phrase =
  let* derived = Phrase.derive phrase in
  let fresh name =
    match Keystore.get_signing_key t.keystore name with
    | Ok (Some k) -> Ok k
    | Ok None ->
        let k = Crypto.generate_signing_key () in
        let* () = Keystore.put_signing_key t.keystore name k in
        Ok k
    | Error e -> Error e
  in
  match Log.get_config t.log k_identity with
  | Some existing when existing <> Keys.public derived.identity ->
      Error "this node was set up with a different recovery phrase"
  | _ ->
      let* device = fresh "device" in
      let* mail = fresh "mail" in
      let* () =
        Keystore.put_encryption_key t.keystore "encryption" derived.encryption
      in
      Log.set_config t.log k_identity (Keys.public derived.identity);
      Log.set_config t.log k_device (Keys.public device);
      Log.set_config t.log k_mail (Keys.public mail);
      Log.set_config t.log k_encryption
        (Keys.encryption_public derived.encryption);
      Ok derived

let need what = function
  | Ok (Some k) -> Ok k
  | Ok None -> Error ("no " ^ what ^ " key; run digestif init")
  | Error e -> Error e

let device_key t = need "device" (Keystore.get_signing_key t.keystore "device")
let mail_key t = need "mail" (Keystore.get_signing_key t.keystore "mail")

let encryption_key t =
  need "encryption" (Keystore.get_encryption_key t.keystore "encryption")

(* The identity, re-derived from the phrase for one signature, checked against the one on record. *)
let identity_from_phrase t phrase =
  let* d = Phrase.derive phrase in
  match Log.get_config t.log k_identity with
  | Some id when id <> Keys.public d.identity ->
      Error "that recovery phrase belongs to a different identity"
  | _ -> Ok d.identity

let fold t =
  match root t with
  | None -> Fold.empty ""
  | Some root -> Fold.run ~root (Log.fold_entries t.log)

(* Write the next envelope of [key]'s chain into the log. It reaches the relays on the next sync,
   which pushes every envelope of ours a relay does not hold. *)
let write t ?(key_name = "device") ~kind body =
  let* key = need key_name (Keystore.get_signing_key t.keystore key_name) in
  let author = Keys.public key in
  let seq, prev =
    match Log.max_seq t.log author with
    | None -> (1, None)
    | Some n -> (
        match Log.by_author_seq t.log ~author ~seq:n with
        | [ r ] -> (n + 1, Some r.hash)
        | _ -> (n + 1, None))
  in
  let f = fold t in
  let sg = Envelope.create ~key ~seq ?prev ~epoch:f.epoch ~kind body in
  let hash = Envelope.hash sg.envelope in
  ignore (Log.insert t.log ~hash sg);
  Ok (hash, sg)

(* Store an envelope written elsewhere (a founding dinner, a join an invite flow built). *)
let import t (sg : Envelope.signed) =
  match Envelope.verify sg with
  | Error e -> Error (Envelope.error_message e)
  | Ok () ->
      let hash = Envelope.hash sg.envelope in
      ignore (Log.insert t.log ~hash sg);
      Ok hash

let own_keys t =
  List.filter_map (fun k -> Log.get_config t.log k) [ k_device; k_mail ]
