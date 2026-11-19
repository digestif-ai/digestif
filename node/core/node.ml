(* One node: its data directory, its log and its keystore, and the acts that need all three. *)

type t = { dir : string; log : Log.t; keystore : Keystore.t }

(* Where a node lives when nothing names its data directory: the platform's place for it. *)
let standard_dir () =
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

let default_dir () =
  match Sys.getenv_opt "DIGESTIF_HOME" with
  | Some d when d <> "" -> d
  | _ -> standard_dir ()

(* [d] as one spelling: its real path when it exists, else absolute without a trailing slash. *)
let canonical_dir d =
  match Unix.realpath d with
  | r -> r
  | exception Unix.Unix_error _ ->
      let a =
        if Filename.is_relative d then Filename.concat (Sys.getcwd ()) d else d
      in
      let n = String.length a in
      if n > 1 && a.[n - 1] = '/' then String.sub a 0 (n - 1) else a

(* Whether [dir] is the machine's first node, the one at the standard place: its service, its UI
   port and the commands on PATH keep their fixed names, and every other node's are derived from
   its data directory (Service). DIGESTIF_HOME does not make a directory standard, since the
   service it installs runs without it. DIG-264 *)
let is_standard dir = canonical_dir dir = canonical_dir (standard_dir ())

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Where a node's log lives in its data directory. *)
let log_path dir = Filename.concat dir "log.sqlite3"

let open_ ?keystore dir =
  mkdir_p dir;
  let keystore =
    match keystore with Some k -> k | None -> Keystore.default ~scope:dir
  in
  { dir; log = Log.open_ (log_path dir); keystore }

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

(* The last seq of [key]'s honest chain as this log holds it: the highest seq held below the first
   seq where the log holds two different envelopes, since a fork is where a second writer began. *)
let honest_seq t key =
  let by_seq = Hashtbl.create 16 in
  List.iter
    (fun (r : Log.row) ->
      let seq = r.signed.envelope.seq in
      let held = Option.value (Hashtbl.find_opt by_seq seq) ~default:[] in
      if not (List.mem r.hash held) then
        Hashtbl.replace by_seq seq (r.hash :: held))
    (Log.by_author t.log key);
  let first_fork =
    Hashtbl.fold
      (fun seq hashes m -> if List.length hashes > 1 then min m seq else m)
      by_seq max_int
  in
  Hashtbl.fold
    (fun seq _ m -> if seq < first_fork then max m seq else m)
    by_seq 0

(* A revoke of [target] signed by [by], with its cutoffs filled from this log: [after_seq] holds each
   device key it stops at its honest seq, [mail_read] each mail key it stops with the hashes of every
   envelope of that key the log holds plus [presigned] (mail key, hash) pairs this node wrote and has
   not seen posted. Fetch every relay first: what the log lacks is lost with the thief's. *)
let revoke_body ?(presigned = []) t ~by ~target =
  let f = fold t in
  match Fold.find f target with
  | None -> Error ("not an admitted key: " ^ target)
  | Some k ->
      let stopped =
        List.sort
          (fun (a : Fold.key_state) b -> compare a.key b.key)
          (Fold.stopped_by f k)
      in
      let after_seq =
        List.filter_map
          (fun (k : Fold.key_state) ->
            if k.role = Device then Some (k.key, honest_seq t k.key) else None)
          stopped
      in
      let mail_read =
        List.filter_map
          (fun (k : Fold.key_state) ->
            if k.role = Mail then
              let held =
                List.map
                  (fun (r : Log.row) -> r.hash)
                  (Log.by_author t.log k.key)
              in
              let unposted =
                List.filter_map
                  (fun (m, h) -> if m = k.key then Some h else None)
                  presigned
              in
              Some (k.key, List.sort_uniq compare (held @ unposted))
            else None)
          stopped
      in
      Ok (Bodies.make_revoke ~by ~target ~after_seq ~mail_read)

(* Where the next envelope of [key]'s chain goes: its seq, and the hash of the one before it. Read
   inside the transaction that stores the envelope (write), so no other process reads the same
   position before this one's envelope is in the log. *)
let next_position t (key : Crypto.signing_key) =
  let author = Keys.public key in
  match Log.max_seq t.log author with
  | None -> (1, None)
  | Some n -> (
      match Log.by_author_seq t.log ~author ~seq:n with
      | [ r ] -> (n + 1, Some r.hash)
      | _ -> (n + 1, None))

(* Keep an envelope this node signed itself; returns its hash. *)
let store t (sg : Envelope.signed) =
  let hash = Envelope.hash sg.envelope in
  ignore (Log.insert ~signed_here:true t.log ~hash sg);
  hash

(* Two writers of one key that both read the same next position would sign two envelopes at one
   seq, a fork of the member's own chain that every node records against the member for good. Every
   act that signs an own envelope at a position it read from the log runs here: across processes
   (the daemon, its per-request connections, a CLI call beside it) the position is read and the
   envelope stored inside one BEGIN IMMEDIATE transaction, and inside this process, where the web
   UI answers each request on a thread of its own (Http.run) and threads may share a connection,
   one at a time under [writing]. Inside a transaction the caller already holds (the daily digest's)
   it is a savepoint of it. envelopes_signed_here_seq refuses whatever slips past both. DIG-229 *)
let writing = Mutex.create ()
let signing t f = Mutex.protect writing (fun () -> Log.transaction t.log f)

(* Write the next envelope of [key]'s chain into the log. It reaches the relays on the next sync,
   which pushes every envelope of ours a relay does not hold. [created_at] is the envelope's signed
   time, now by default: a caller that judged something against a time (an answer against its
   question's lapse, DIG-86) signs with that same time. *)
let write t ?(key_name = "device") ?created_at ~kind body =
  let* key = need key_name (Keystore.get_signing_key t.keystore key_name) in
  signing t (fun () ->
      let seq, prev = next_position t key in
      let f = fold t in
      let sg =
        Envelope.create ~key ~seq ?prev ?created_at ~epoch:f.epoch ~kind body
      in
      Ok (store t sg, sg))

(* A member who runs a relay adds it here and publishes a relay message naming it, which every other
   node's sync adds (design.md, Two relays to start). A relay the circle already names is not
   announced again. *)
let add_own_relay t url =
  if not (Relay_url.from_circle url) then
    Error
      (url
     ^ " is not a public https relay, so no other node would add it; use \
        digestif relay add without --mine for a relay only this node reads")
  else begin
    Log.add_relay t.log url;
    if Hashtbl.mem (fold t).relays url then Ok None
    else
      let* hash, _ =
        write t ~kind:"relay" (Bodies.make_relay ~url ~mailer:false ())
      in
      Ok (Some hash)
  end

(* Store an envelope written elsewhere (a circle root, a join an invite flow built). *)
let import t (sg : Envelope.signed) =
  match Envelope.verify sg with
  | Error e -> Error (Envelope.error_message e)
  | Ok () ->
      let hash = Envelope.hash sg.envelope in
      ignore (Log.insert t.log ~hash sg);
      Ok hash

let own_keys t =
  List.filter_map (fun k -> Log.get_config t.log k) [ k_device; k_mail ]

(* The keystore name of the own key whose public half is [author]. *)
let own_key_name t author =
  List.find_map
    (fun (config, name) ->
      if Log.get_config t.log config = Some author then Some name else None)
    [ (k_device, "device"); (k_mail, "mail") ]

(* The signing key of the own key whose public half is [author]: a relay takes an envelope only with
   its author as the request signer (relay/src/append.ts), so a mail key's envelope goes out signed
   by the mail key, never by the device. *)
let own_signing_key t author =
  match own_key_name t author with
  | None -> Error ("not an own key: " ^ author)
  | Some name -> need name (Keystore.get_signing_key t.keystore name)

(* [body] with every string naming a key of [moved] replaced by what it maps to: a later envelope
   that names an earlier one re-signed beside it (a reply, a retract) names the new hash. *)
let rec remap_hashes moved (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String h -> (
      match List.assoc_opt h moved with Some h' -> `String h' | None -> j)
  | `Assoc fs -> `Assoc (List.map (fun (k, v) -> (k, remap_hashes moved v)) fs)
  | `List xs -> `List (List.map (remap_hashes moved) xs)
  | j -> j

(* What becomes of a later envelope [drop_refused] would re-sign. [Resign] re-signs it one seq lower
   with every moved hash in its body remapped; [Drop after] removes it beside the refused one, for
   an envelope whose body seals something naming a moved hash that no remap can reach (a digest's
   pre-signed answers name the ask they answer), and runs [after] in the same transaction once it
   is gone, so the store that wrote it can write it again. A store registers its check for a kind
   where it writes that kind; the check reads the envelope as it was, before any remap. *)
type resign = Resign | Drop of (unit -> unit)

let resign_checks :
    (string * (t -> moved:(string * string) list -> Log.row -> resign)) list ref
    =
  ref []

let register_resign_check ~kind f =
  resign_checks := (kind, f) :: List.remove_assoc kind !resign_checks

let resign_check t ~moved (r : Log.row) =
  match List.assoc_opt r.signed.envelope.kind !resign_checks with
  | Some f -> f t ~moved r
  | None -> Resign

(* What a store does when [drop_refused] drops an envelope of a kind it writes, in the same
   transaction, once the envelope is gone: a digest's store reads again what the refused digest
   took as read. The check reads the envelope as it was. *)
let refused_checks : (string * (t -> Log.row -> unit)) list ref = ref []

let register_refused_check ~kind f =
  refused_checks := (kind, f) :: List.remove_assoc kind !refused_checks

let refused_check t (r : Log.row) =
  match List.assoc_opt r.signed.envelope.kind !refused_checks with
  | Some f -> f t r
  | None -> ()

(* A relay refused an own envelope for good (protocol.md, Chains, "A refused envelope never
   existed"): drop it, and re-sign every later envelope of its chain one seq lower, each naming as
   prev the one now before it, so the chain other nodes read has no gap where it was. Only an
   envelope no relay holds is dropped, and only while no relay holds a later one of its chain:
   anything a relay holds another node may have read, and re-signing it would fork the chain. A
   mail key is chainless (its prev is the ask it answers), so a refused mail envelope is dropped
   and nothing after it is touched. A later envelope its kind's check drops (resign_check) is
   removed rather than re-signed, and the ones after it close up behind it. The chain is read and
   re-signed under [signing], as a write is, so no write signs at a seq this moves. A check run here
   writes no envelope of its own: [writing] is not reentrant. Returns how many envelopes were
   re-signed. DIG-229 *)
let drop_refused t (row : Log.row) =
  signing t (fun () ->
      let e = row.signed.envelope in
      let author = e.author in
      let chainless =
        own_key_name t author = Some "mail" || Fold.is_chainless (fold t) author
      in
      let later =
        if chainless then []
        else
          List.filter
            (fun (r : Log.row) -> r.signed.envelope.seq > e.seq)
            (Log.by_author t.log author)
      in
      let seqs = List.map (fun (r : Log.row) -> r.signed.envelope.seq) later in
      if Envelope.is_bootstrap row.signed then
        Error "a dinner, join or self-authored device message is never dropped"
      else if
        List.exists
          (fun (r : Log.row) -> Log.sighted t.log r.hash)
          (row :: later)
      then Error "a relay holds it or a later envelope of its chain"
      else if List.length (List.sort_uniq compare seqs) <> List.length seqs then
        Error "its chain forks after it"
      else if List.exists (fun (r : Log.row) -> r.signed.body = None) later then
        Error "a later envelope of its chain has no body to re-sign"
      else
        let* key = own_signing_key t author in
        let prev =
          if e.seq <= 1 then None
          else
            match Log.by_author_seq t.log ~author ~seq:(e.seq - 1) with
            | [ r ] -> Some r.hash
            | _ -> e.prev
        in
        begin
          Log.delete t.log row.hash;
          refused_check t row;
          let _, _, moved =
            List.fold_left
              (fun (seq, prev, moved) (r : Log.row) ->
                match resign_check t ~moved r with
                | Drop after ->
                    Log.delete t.log r.hash;
                    after ();
                    (seq, prev, moved)
                | Resign ->
                    let old = r.signed.envelope in
                    let body = remap_hashes moved (Option.get r.signed.body) in
                    let sg =
                      Envelope.create ~key ~seq ?prev ~created_at:old.created_at
                        ~epoch:old.epoch ~kind:old.kind body
                    in
                    let hash = Envelope.hash sg.envelope in
                    Log.rewrite t.log ~old_hash:r.hash ~hash sg;
                    (seq + 1, Some hash, (r.hash, hash) :: moved))
              (e.seq, prev, []) later
          in
          Ok (List.length moved)
        end)

(* The device message this node signed for [key] in [role] and no relay holds yet: the one a repeat
   of digestif device publish resumes rather than signing a second. *)
let pending_device t ~key ~role =
  match Log.get_config t.log k_device with
  | None -> None
  | Some device ->
      let authors = List.sort_uniq compare [ device; key ] in
      List.concat_map (fun a -> Log.by_author t.log a) authors
      |> List.find_opt (fun (r : Log.row) ->
          r.signed.envelope.kind = "device"
          && (not (Log.sighted t.log r.hash))
          &&
          match Option.map Bodies.parse_device r.signed.body with
          | Some (Ok d) -> d.key = key && d.role = role
          | _ -> false)

(* digestif device publish: resume the pending device message for [key], refuse a key the fold
   already admits, or sign a new one with the identity [identity] gives (read only then). *)
let publish_device t ~key ~role ~identity =
  match pending_device t ~key ~role with
  | Some r -> Ok (`Pending r.hash)
  | None -> (
      match Fold.find (fold t) key with
      | Some _ -> Error ("this key is already admitted: " ^ key)
      | None ->
          let* identity = identity () in
          let body = Bodies.make_device ~identity ~key ~role in
          let* hash, _ = write t ~kind:"device" body in
          Ok (`Signed hash))
