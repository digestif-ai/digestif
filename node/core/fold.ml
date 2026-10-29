(* The admission fold (protocol.md, The admission fold). A relay folds in its own relay order; a node
   reads several relays whose orders differ, so it folds the union in one order every node agrees on:
   the root dinner first, then every other circle-state envelope by (created_at, hash), applied in
   passes until a pass applies nothing. An envelope whose prerequisite has not arrived (a join before
   its dinner, a device before its identity) waits for a later pass rather than failing, so two nodes
   holding the same envelopes compute the same fold whatever order the relays delivered them in. An
   invite's expiry is judged against the join's created_at; relays enforce it against their own
   clocks.

   A revoked key is read by its cutoff, never by where its envelopes fall in that order: a device key
   at or below the revoke's after_seq and none above, a mail key the envelopes mail_read lists and no
   other. created_at is the author's clock, and so the thief's once a key is stolen. An envelope past
   a cutoff that folded anyway (its created_at put it ahead of the revoke) is left out and the whole
   fold run again, since it may have admitted keys or guests of its own. *)

module Hashes = Set.Make (String)

type entry = {
  hash : string;
  envelope : Envelope.t;
  body : Yojson.Safe.t option;
}

type key_state = {
  key : string;
  role : Bodies.role;
  identity : string;
  admitted_by : string;
  join_epoch : int;
  mutable revoked_by : string option;
  mutable after_seq : int option;
      (** A revoked device key's cutoff: the highest seq still read from it. *)
  mutable mail_read : Hashes.t option;
      (** A revoked mail key's cutoff: the envelope hashes still read from it.
      *)
}

type invite = {
  invite_key : string;
  dinner : string;
  host_identity : string;
  expires_at : float;
  mutable spent_by : string option;
}

type t = {
  root : string;
  mutable epoch : int;
  keys : (string, key_state) Hashtbl.t;
  invites : (string, invite) Hashtbl.t;
  dinners : (string, string) Hashtbl.t;  (** dinner hash -> host identity *)
  admitted_by_host : (string, string) Hashtbl.t;
      (** identity -> the host identity whose dinner admitted it *)
  cards : (string, Bodies.card * string) Hashtbl.t;
      (** identity -> card, envelope hash *)
  relays : (string, Bodies.relay) Hashtbl.t;
  revokes : (string, entry) Hashtbl.t;  (** revoke envelope hash -> entry *)
  mutable applied : string list;  (** in application order *)
  mutable rejected : (string * string) list;  (** hash, reason *)
  mutable waiting : (string * string) list;  (** hash, what it waits for *)
}

type outcome = Applied | Waiting of string | Rejected of string

let empty root =
  {
    root;
    epoch = 0;
    keys = Hashtbl.create 64;
    invites = Hashtbl.create 64;
    dinners = Hashtbl.create 8;
    admitted_by_host = Hashtbl.create 16;
    cards = Hashtbl.create 16;
    relays = Hashtbl.create 8;
    revokes = Hashtbl.create 8;
    applied = [];
    rejected = [];
    waiting = [];
  }

let find t key = Hashtbl.find_opt t.keys key

let order a b =
  match compare a.envelope.created_at b.envelope.created_at with
  | 0 -> compare a.hash b.hash
  | c -> c

(* Whether a revoked key's envelope at [seq] with [hash] is inside the key's cutoff. *)
let within_cutoff k ~seq ~hash =
  match (k.after_seq, k.mail_read) with
  | Some cutoff, _ -> seq <= cutoff
  | None, Some hashes -> Hashes.mem hash hashes
  | None, None -> false

(* The author may speak for this entry: admitted, and unrevoked or inside its cutoff. *)
let author_in_force t entry key =
  match find t key with
  | None -> None
  | Some k -> (
      match k.revoked_by with
      | None -> Some k
      | Some _ ->
          if within_cutoff k ~seq:entry.envelope.seq ~hash:entry.hash then
            Some k
          else None)

(* A node must not read this envelope: its author is revoked and it is outside the cutoff. *)
let past_cutoff t entry =
  match find t entry.envelope.author with
  | Some ({ revoked_by = Some _; _ } as k) ->
      not (within_cutoff k ~seq:entry.envelope.seq ~hash:entry.hash)
  | _ -> false

let admit t ~key ~role ~identity ~admitted_by ~join_epoch =
  if not (Hashtbl.mem t.keys key) then
    Hashtbl.replace t.keys key
      {
        key;
        role;
        identity;
        admitted_by;
        join_epoch;
        revoked_by = None;
        after_seq = None;
        mail_read = None;
      }

let record_dinner t ~hash (d : Bodies.dinner) =
  Hashtbl.replace t.dinners hash d.host;
  List.iter
    (fun (g : Bodies.guest) ->
      if not (Hashtbl.mem t.invites g.invite_key) then
        match Time_fmt.to_unix g.expires_at with
        | Some expires_at ->
            Hashtbl.replace t.invites g.invite_key
              {
                invite_key = g.invite_key;
                dinner = hash;
                host_identity = d.host;
                expires_at;
                spent_by = None;
              }
        | None -> ())
    d.guests

let parse_body entry parse =
  match entry.body with
  | None -> Error "body withheld or dropped"
  | Some b -> parse b

let apply_root t entry =
  match parse_body entry Bodies.parse_dinner with
  | Error m -> Rejected ("root dinner: " ^ m)
  | Ok d ->
      admit t ~key:d.host ~role:Identity ~identity:d.host
        ~admitted_by:entry.hash ~join_epoch:0;
      admit t ~key:entry.envelope.author ~role:Device ~identity:d.host
        ~admitted_by:entry.hash ~join_epoch:0;
      record_dinner t ~hash:entry.hash d;
      Applied

let device_author t entry =
  match author_in_force t entry entry.envelope.author with
  | Some ({ role = Device; _ } as k) -> Ok k
  | Some _ -> Error (Rejected "author is not a device key")
  | None ->
      if Hashtbl.mem t.keys entry.envelope.author then
        Error (Rejected "author revoked")
      else Error (Waiting ("author " ^ entry.envelope.author))

let apply_dinner t entry =
  match device_author t entry with
  | Error o -> o
  | Ok author -> (
      match parse_body entry Bodies.parse_dinner with
      | Error m -> Rejected m
      | Ok d when d.host <> author.identity ->
          Rejected "dinner host is not the author's identity"
      | Ok d ->
          record_dinner t ~hash:entry.hash d;
          Applied)

let apply_join t entry =
  match parse_body entry Bodies.parse_join with
  | Error m -> Rejected m
  | Ok j -> (
      match Hashtbl.find_opt t.invites entry.envelope.author with
      | None -> Waiting ("invite key " ^ entry.envelope.author)
      | Some inv ->
          if not (Hashtbl.mem t.dinners j.dinner_hash) then
            Waiting ("dinner " ^ j.dinner_hash)
          else if inv.dinner <> j.dinner_hash then
            Rejected "the invite key belongs to another dinner"
          else if
            not (Bodies.join_signatures_valid ~invite_key:inv.invite_key j)
          then Rejected "bad_signature"
          else if inv.spent_by <> None then Rejected "invite already spent"
          else if
            match Time_fmt.to_unix entry.envelope.created_at with
            | Some at -> at >= inv.expires_at
            | None -> true
          then Rejected "invite expired"
          else if Hashtbl.mem t.keys j.device_key then
            Rejected "device key already admitted"
          else begin
            inv.spent_by <- Some entry.hash;
            t.epoch <- t.epoch + 1;
            (match find t j.identity_key with
            | Some { role = Identity; _ } -> ()
            | Some _ -> ()
            | None ->
                admit t ~key:j.identity_key ~role:Identity
                  ~identity:j.identity_key ~admitted_by:entry.hash
                  ~join_epoch:t.epoch;
                Hashtbl.replace t.admitted_by_host j.identity_key
                  inv.host_identity);
            let join_epoch =
              match find t j.identity_key with
              | Some k -> k.join_epoch
              | None -> t.epoch
            in
            admit t ~key:j.device_key ~role:Device ~identity:j.identity_key
              ~admitted_by:entry.hash ~join_epoch;
            Applied
          end)

(* A device message's authority is its identity signature. Its author is a device of the same
   identity, or the new key itself: a member who lost their only laptop has no other device to post
   from, and re-derives the identity from the phrase to sign the new key in. *)
let apply_device t entry =
  match parse_body entry Bodies.parse_device with
  | Error m -> Rejected m
  | Ok d -> (
      match find t d.d_identity_key with
      | None -> Waiting ("identity " ^ d.d_identity_key)
      | Some { role = Identity | Device | Mail; revoked_by = Some _; _ } ->
          Rejected "identity revoked"
      | Some { role = Device | Mail; _ } ->
          Rejected "identity_key is not an identity"
      | Some ident -> (
          if not (Bodies.device_signature_valid d) then Rejected "bad_signature"
          else
            let author_ok =
              if entry.envelope.author = d.key then Ok ()
              else
                match author_in_force t entry entry.envelope.author with
                | Some k when k.identity = d.d_identity_key && k.role = Device
                  ->
                    Ok ()
                | Some _ ->
                    Error (Rejected "author is not a device of this identity")
                | None ->
                    if Hashtbl.mem t.keys entry.envelope.author then
                      Error (Rejected "author revoked")
                    else Error (Waiting ("author " ^ entry.envelope.author))
            in
            match author_ok with
            | Error o -> o
            | Ok () -> (
                match find t d.key with
                | Some k when k.identity = d.d_identity_key -> Applied
                | Some _ ->
                    Rejected "key already admitted under another identity"
                | None ->
                    admit t ~key:d.key ~role:d.role ~identity:d.d_identity_key
                      ~admitted_by:entry.hash ~join_epoch:ident.join_epoch;
                    Applied)))

(* The keys a revoke of [target] stops: the target, or every key under a target identity. *)
let stopped_by t (target : key_state) =
  match target.role with
  | Identity ->
      Hashtbl.fold
        (fun _ k acc -> if k.identity = target.key then k :: acc else acc)
        t.keys []
  | Device | Mail -> [ target ]

(* A key named in after_seq must be a device key the revoke stops, one in mail_read a mail key. *)
let check_cutoff_keys stopped (r : Bodies.revoke) =
  let stops role key =
    List.exists (fun k -> k.key = key && k.role = role) stopped
  in
  match
    ( List.find_opt (fun (k, _) -> not (stops Device k)) r.after_seq,
      List.find_opt (fun (k, _) -> not (stops Mail k)) r.mail_read )
  with
  | Some (k, _), _ ->
      Error ("after_seq names " ^ k ^ ", not a device key it stops")
  | _, Some (k, _) ->
      Error ("mail_read names " ^ k ^ ", not a mail key it stops")
  | None, None -> Ok ()

(* Two revokes stopping one key leave the lower cutoff, and for a mail key the hashes both list. *)
let record_cutoff (r : Bodies.revoke) ~revoke k =
  if k.revoked_by = None then k.revoked_by <- Some revoke;
  match k.role with
  | Device ->
      let cutoff = Option.value (List.assoc_opt k.key r.after_seq) ~default:0 in
      k.after_seq <-
        Some (match k.after_seq with Some c -> min c cutoff | None -> cutoff)
  | Mail ->
      let listed =
        Hashes.of_list
          (Option.value (List.assoc_opt k.key r.mail_read) ~default:[])
      in
      k.mail_read <-
        Some
          (match k.mail_read with
          | Some held -> Hashes.inter held listed
          | None -> listed)
  | Identity -> ()

let apply_revoke t entry =
  match parse_body entry Bodies.parse_revoke with
  | Error m -> Rejected ("malformed: " ^ m)
  | Ok r -> (
      match (find t r.by, find t r.target) with
      | None, _ -> Waiting ("identity " ^ r.by)
      | _, None -> Waiting ("target " ^ r.target)
      | Some by, Some target -> (
          if by.role <> Identity then Rejected "by is not an identity"
          else if not (Bodies.revoke_signature_valid r) then
            Rejected "bad_signature"
          else
            let authorized =
              match target.role with
              | Device | Mail -> target.identity = r.by
              | Identity ->
                  r.target = r.by
                  || Hashtbl.find_opt t.admitted_by_host r.target = Some r.by
            in
            if not authorized then Rejected "by may not revoke this target"
            else
              match author_in_force t entry entry.envelope.author with
              | None ->
                  if Hashtbl.mem t.keys entry.envelope.author then
                    Rejected "author revoked"
                  else Waiting ("author " ^ entry.envelope.author)
              | Some author
                when author.role <> Device || author.identity <> r.by ->
                  Rejected "author is not a device key of by"
              | Some _ -> (
                  let stopped = stopped_by t target in
                  match check_cutoff_keys stopped r with
                  | Error m -> Rejected ("malformed: " ^ m)
                  | Ok () ->
                      Hashtbl.replace t.revokes entry.hash entry;
                      List.iter (record_cutoff r ~revoke:entry.hash) stopped;
                      Applied)))

let apply_card t entry =
  match device_author t entry with
  | Error o -> o
  | Ok author -> (
      match parse_body entry Bodies.parse_card with
      | Error m -> Rejected m
      | Ok c ->
          Hashtbl.replace t.cards author.identity (c, entry.hash);
          Applied)

let apply_relay t entry =
  match device_author t entry with
  | Error o -> o
  | Ok _ -> (
      match parse_body entry Bodies.parse_relay with
      | Error m -> Rejected m
      | Ok r ->
          Hashtbl.replace t.relays r.url r;
          Applied)

let apply t entry =
  match entry.envelope.kind with
  | "dinner" -> apply_dinner t entry
  | "join" -> apply_join t entry
  | "device" -> apply_device t entry
  | "revoke" -> apply_revoke t entry
  | "card" -> apply_card t entry
  | "relay" -> apply_relay t entry
  | k -> Rejected ("not a circle-state kind: " ^ k)

(* One fold of the circle-state entries from [root], leaving out [excluded]. *)
let run_once ~root ~excluded entries =
  let t = empty root in
  let circle =
    List.filter
      (fun e ->
        Envelope.is_circle_state e.envelope.kind
        && not (Hashes.mem e.hash excluded))
      entries
  in
  match List.find_opt (fun e -> e.hash = root) circle with
  | None ->
      t.waiting <- [ (root, "the root dinner is not in the log") ];
      t
  | Some r -> (
      match apply_root t r with
      | Rejected m ->
          t.rejected <- [ (root, m) ];
          t
      | _ ->
          t.applied <- [ root ];
          let rec pass pending =
            let progressed = ref false in
            let still =
              List.filter_map
                (fun e ->
                  match apply t e with
                  | Applied ->
                      progressed := true;
                      t.applied <- e.hash :: t.applied;
                      None
                  | Rejected m ->
                      progressed := true;
                      t.rejected <- (e.hash, m) :: t.rejected;
                      None
                  | Waiting w -> Some (e, w))
                pending
            in
            if !progressed && still <> [] then pass (List.map fst still)
            else t.waiting <- List.map (fun (e, w) -> (e.hash, w)) still
          in
          pass (List.sort order (List.filter (fun e -> e.hash <> root) circle));
          t.applied <- List.rev t.applied;
          t)

(* Fold every circle-state entry from [root]; entries of other kinds are ignored. A folded entry past
   its author's cutoff is left out and the fold run again, until nothing folded is past a cutoff. The
   root dinner is never left out: a revoke that cut it off would leave no circle to read. *)
let run ~root entries =
  let by_hash = Hashtbl.create 64 in
  List.iter (fun e -> Hashtbl.replace by_hash e.hash e) entries;
  let rec go excluded =
    let t = run_once ~root ~excluded entries in
    let past =
      List.filter
        (fun h ->
          h <> root
          &&
          match Hashtbl.find_opt by_hash h with
          | Some e -> past_cutoff t e
          | None -> false)
        t.applied
    in
    if past = [] then t
    else go (List.fold_left (fun s h -> Hashes.add h s) excluded past)
  in
  go Hashes.empty

(* Whether a node reads a content envelope: an admitted device or mail key, in force when it wrote. *)
let reads_content t entry =
  match author_in_force t entry entry.envelope.author with
  | Some { role = Device | Mail; _ } -> true
  | _ -> false

let is_chainless t key =
  match find t key with Some { role = Mail; _ } -> true | _ -> false

let identity_of t key = Option.map (fun k -> k.identity) (find t key)
