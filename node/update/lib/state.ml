(* What a node has installed and whom it trusts to sign the next release, kept in one JSON file.
   Written atomically and synced to disk, so a crash or a power loss leaves the old state or the new
   one, and every read-modify-write holds a lock ([update]), so two writers (the service's pass,
   its web UI, the supervisor, a person's `digestif update`) never lose each other's change. *)

open Release

(* A release this node will not take again: its self-test failed, or it did not report healthy
   after the switch and the supervisor moved back (docs/releases.md, Switching). *)
type refused = { refused_version : Version.t; why : string }

(* A release the node chose and could not take yet: a stage that failed for this machine (a download
   that broke, Node.js missing), or a failure that may be this machine or the release (a self-test
   past its bound, a trial that did not report healthy in time, Stage.Suspect). The pass that finds
   it due tries again; until then the node keeps what it runs. [strikes] counts the second kind:
   [strike_limit] of them refuse the version for good, since a release that fails the same way on
   every try is the release. *)
type pending = {
  pending_version : Version.t;
  cause : string;
  attempts : int;
  due_at : float;
  strikes : int;
}

type t = {
  installed : Version.t;
      (** The version that last reported healthy after a switch: what newer-only
          compares to. *)
  trust : Policy.trust;
  pin : Version.t option;
  refused : refused list;
  pending : pending option;
  first_installed : (Version.t * float) list;
      (** When this node first installed each version it ran, Unix time. A move
          back never resets it, so a recall's week (Recall) is measured from a
          version's first install. *)
  build_signers : Keys.public_key list option;
      (** The keys the build that last loaded this file named, so only a build
          naming a set this file has not seen is adopted ([reconcile_signers]).
          [None] in a file written before it was kept. *)
  signer_sets : signer_set signed list;
      (** Every signer-set change this node adopted, from the circle or the
          channel, in the order it adopted them: never adopted twice, posted to
          a circle that lacks one (Circle_signer_set) and published to a channel
          that lacks one by sign --next (Signers_channel). *)
}

let ( let* ) = Result.bind

let keys_of (signers : signer list) =
  List.map (fun (s : signer) -> s.key) signers

let initial () =
  let build = Trust_root.signers () in
  {
    installed = Trust_root.version ();
    trust = { signers = build; revoked = [] };
    pin = None;
    refused = [];
    pending = None;
    first_installed = [];
    build_signers = Some (keys_of build);
    signer_sets = [];
  }

(* Adopt every change of [changes] that verifies against the set [t] holds, link by link
   (Policy.adopt_sets), recording each in [t.signer_sets]. Answers the state and the changes it
   newly adopted. *)
let adopt_sets t ~revocations changes =
  let a =
    Policy.adopt_sets
      ~seen:(List.map (fun (c : signer_set signed) -> c.bytes) t.signer_sets)
      t.trust ~revocations changes
  in
  ( { t with trust = a.adopted_trust; signer_sets = t.signer_sets @ a.adopted },
    a )

(* Seconds before the next try after [attempts] failed tries: 10 minutes, doubling, at most a day. *)
let backoff attempts =
  Float.min 86_400. (600. *. (2. ** float_of_int (max 0 (attempts - 1))))

(* Failures that may be this machine before a version is refused for good. *)
let strike_limit = 3
let struck_out_suffix = Printf.sprintf " (on %d tries)" strike_limit

(* Whether a refusal came from [strike_limit] failures that may each have been this machine. *)
let struck_out why = String.ends_with ~suffix:struck_out_suffix why

let is_refused t v =
  List.exists (fun r -> Version.equal r.refused_version v) t.refused

let refuse t v why =
  if is_refused t v then t
  else { t with refused = t.refused @ [ { refused_version = v; why } ] }

(* A failure of [v] that may be this machine or the release ([why]): kept as pending, tried again
   after the backoff, and refused for good on the [strike_limit]th. *)
let strike t v why ~now =
  let attempts, strikes =
    match t.pending with
    | Some p when Version.equal p.pending_version v ->
        (p.attempts + 1, p.strikes + 1)
    | _ -> (1, 1)
  in
  if strikes >= strike_limit then
    refuse { t with pending = None } v (why ^ struck_out_suffix)
  else
    {
      t with
      pending =
        Some
          {
            pending_version = v;
            cause = why;
            attempts;
            due_at = now +. backoff attempts;
            strikes;
          };
    }

let first_installed_at t v =
  List.find_map
    (fun (w, at) -> if Version.equal w v then Some at else None)
    t.first_installed

(* Record that this node runs [v] from [now] on, unless it ran [v] before: the first install is
   the one that counts. *)
let note_install t v ~now =
  if first_installed_at t v <> None then t
  else { t with first_installed = t.first_installed @ [ (v, now) ] }

(* The build's signer set, adopted when the stored set is a strict subset of it, none of its keys is
   revoked, and it is not the set this file last saw a build name. A node first written by a build
   that knew one signer otherwise stays on that set forever and installs nothing. The last condition
   keeps a signed change that shrank the set: the build that named the larger set has already been
   seen, so it does not put the removed signer back on every load. This does not weaken the
   two-signer rule: the binary that holds this set is one the member built or installed, so it is
   already their trust root, and anyone who could change the set it embeds could change the code
   that checks signatures just as well. A node that adopted a signed signer-set change holds the set
   that chain leaves, and no build widens it: a binary built before a removal (an older supervisor,
   a release the node moved back to) would otherwise put the removed signer back. Every later
   signer reaches the node as a signed change of its own. *)
let reconcile_signers ?(adopted = []) ~build ~seen (trust : Policy.trust) =
  let stored = keys_of trust.signers and named = keys_of build in
  let same a b = List.sort compare a = List.sort compare b in
  let strict_subset =
    List.for_all (fun k -> List.mem k named) stored
    && List.exists (fun k -> not (List.mem k stored)) named
  in
  let revoked k = List.mem k trust.revoked in
  let already_seen =
    match seen with Some keys -> same keys named | None -> false
  in
  if
    adopted = [] && strict_subset
    && (not (List.exists revoked named))
    && not already_seen
  then { trust with signers = build }
  else trust

(* The signers a node that adopted signed signer-set changes holds: the set the last change it
   adopted names. A file a build widened anyway (an older supervisor's binary, built before this
   rule, reconciling on its own load) comes back to that set on the next load. DIG-223 *)
let held_by_chain t =
  match List.rev t.signer_sets with
  | [] -> t
  | last :: _ ->
      { t with trust = { t.trust with signers = last.doc.set_signers } }

let to_string t =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [
         ("format", `String "digestif-update-state-v0");
         ("installed", `String (Version.to_string t.installed));
         ( "pin",
           match t.pin with
           | None -> `Null
           | Some v -> `String (Version.to_string v) );
         ("signers", `List (List.map signer_to_json t.trust.signers));
         ("revoked", `List (List.map (fun k -> `String k) t.trust.revoked));
         ( "refused",
           `List
             (List.map
                (fun r ->
                  `Assoc
                    [
                      ("version", `String (Version.to_string r.refused_version));
                      ("why", `String r.why);
                    ])
                t.refused) );
         ( "pending",
           match t.pending with
           | None -> `Null
           | Some p ->
               `Assoc
                 [
                   ("version", `String (Version.to_string p.pending_version));
                   ("cause", `String p.cause);
                   ("attempts", `Int p.attempts);
                   ("due_at", `Float p.due_at);
                   ("strikes", `Int p.strikes);
                 ] );
         ( "first_installed",
           `List
             (List.map
                (fun (v, at) ->
                  `Assoc
                    [
                      ("version", `String (Version.to_string v));
                      ("at", `Float at);
                    ])
                t.first_installed) );
         ( "build_signers",
           match t.build_signers with
           | None -> `Null
           | Some keys -> `List (List.map (fun k -> `String k) keys) );
         ("signer_sets", `List (List.map body_of_signed t.signer_sets));
       ])
  ^ "\n"

let of_string bytes =
  let* json = parse_json "update state" bytes in
  let* () = expect_format "digestif-update-state-v0" json in
  let* installed = string_field "installed" json in
  let* installed = Version.of_string installed in
  let* pin =
    match field "pin" json with
    | None | Some `Null -> Ok None
    | Some (`String s) ->
        let* v = Version.of_string s in
        Ok (Some v)
    | Some _ -> Error "field \"pin\" must be a string"
  in
  let* signers = list_field "signers" json in
  let* signers = all signer_of_json signers in
  let* revoked = list_field "revoked" json in
  let* revoked =
    all
      (function
        | `String k -> Keys.parse_ed25519 k
        | _ -> Error "revoked keys are strings")
      revoked
  in
  let version_of json =
    let* v = string_field "version" json in
    Version.of_string v
  in
  let* refused =
    match field "refused" json with
    | None | Some `Null -> Ok []
    | Some (`List l) ->
        all
          (fun j ->
            let* refused_version = version_of j in
            let* why = optional_string "why" j in
            Ok { refused_version; why })
          l
    | Some _ -> Error "field \"refused\" must be a list"
  in
  let* pending =
    match field "pending" json with
    | None | Some `Null -> Ok None
    | Some j ->
        let* pending_version = version_of j in
        let* cause = optional_string "cause" j in
        let attempts =
          match field "attempts" j with Some (`Int n) -> n | _ -> 1
        in
        let due_at =
          match field "due_at" j with
          | Some (`Float f) -> f
          | Some (`Int i) -> float_of_int i
          | _ -> 0.
        in
        let strikes =
          match field "strikes" j with Some (`Int n) -> n | _ -> 0
        in
        Ok (Some { pending_version; cause; attempts; due_at; strikes })
  in
  let* first_installed =
    match field "first_installed" json with
    | None | Some `Null -> Ok []
    | Some (`List l) ->
        all
          (fun j ->
            let* v = version_of j in
            match field "at" j with
            | Some (`Float f) -> Ok (v, f)
            | Some (`Int i) -> Ok (v, float_of_int i)
            | _ -> Error "first_installed times are numbers")
          l
    | Some _ -> Error "field \"first_installed\" must be a list"
  in
  let* build_signers =
    match field "build_signers" json with
    | None | Some `Null -> Ok None
    | Some (`List l) ->
        let* keys =
          all
            (function
              | `String k -> Keys.parse_ed25519 k
              | _ -> Error "build_signers keys are strings")
            l
        in
        Ok (Some keys)
    | Some _ -> Error "field \"build_signers\" must be a list"
  in
  let* signer_sets =
    match field "signer_sets" json with
    | None | Some `Null -> Ok []
    | Some (`List l) -> all (signed_of_body signer_set_of_string) l
    | Some _ -> Error "field \"signer_sets\" must be a list"
  in
  Ok
    {
      installed;
      trust = { signers; revoked };
      pin;
      refused;
      pending;
      first_installed;
      build_signers;
      signer_sets;
    }

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* [fd] synced to disk; a file system that cannot sync a directory is not an error. *)
let fsync_fd fd = try Unix.fsync fd with Unix.Unix_error _ -> ()

let fsync_dir dir =
  match Unix.openfile dir [ Unix.O_RDONLY ] 0 with
  | fd -> Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> fsync_fd fd)
  | exception Unix.Unix_error _ -> ()

(* [contents] at [path], or the old bytes: written beside it, synced, renamed over it, and the
   rename synced, so neither a crash nor a power loss leaves a torn or empty file. *)
let write_atomic path contents =
  let tmp = path ^ ".tmp" in
  let fd =
    Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let b = Bytes.unsafe_of_string contents in
      let rec go off =
        if off < Bytes.length b then
          go (off + Unix.write fd b off (Bytes.length b - off))
      in
      go 0;
      fsync_fd fd);
  Unix.rename tmp path;
  fsync_dir (Filename.dirname path)

(* The state at [path], or the build's own state when the file does not exist yet. A file that
   exists and does not parse is an error, never silently replaced by the build's trust root. With
   [reconcile] (the default), a stored signer set that a build not seen before extends reaches the
   build's ([reconcile_signers]), and the file then records that build's set as seen; the supervisor
   reads without it, since it only records a trial's verdict and its binary is the oldest one the
   node runs. *)
let load ?(build = Trust_root.signers ()) ?(reconcile = true) path =
  if Sys.file_exists path then
    match Result.map held_by_chain (of_string (read_file path)) with
    | Ok t when reconcile ->
        Ok
          {
            t with
            trust =
              reconcile_signers ~adopted:t.signer_sets ~build
                ~seen:t.build_signers t.trust;
            build_signers = Some (keys_of build);
          }
    | Ok t -> Ok t
    | Error e -> Error (path ^ ": " ^ e)
  else Ok (initial ())

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o700
  end

let save path t =
  mkdir_p (Filename.dirname path);
  write_atomic path (to_string t)

(* The lock every read-modify-write of a state file holds: a mutex for the threads of this process
   (the service's loop and its web UI), and an fcntl lock on <path>.lock for other processes (the
   supervisor, `digestif update` run by a person). Reentrant within a thread, so a pass that holds
   it may call code that takes it again. *)
let mutex = Mutex.create ()
let owner : (int * int) option Atomic.t = Atomic.make None

let with_lock path f =
  let me = Thread.id (Thread.self ()) in
  match Atomic.get owner with
  | Some (t, depth) when t = me ->
      Atomic.set owner (Some (t, depth + 1));
      Fun.protect ~finally:(fun () -> Atomic.set owner (Some (t, depth))) f
  | _ ->
      Mutex.lock mutex;
      Fun.protect
        ~finally:(fun () ->
          Atomic.set owner None;
          Mutex.unlock mutex)
        (fun () ->
          Atomic.set owner (Some (me, 1));
          mkdir_p (Filename.dirname path);
          let fd =
            Unix.openfile (path ^ ".lock") [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
          in
          Fun.protect
            ~finally:(fun () -> Unix.close fd)
            (fun () ->
              let rec lock () =
                try Unix.lockf fd Unix.F_LOCK 0
                with Unix.Unix_error (Unix.EINTR, _, _) -> lock ()
              in
              lock ();
              f ()))

(* Load the state at [path], apply [f], and save what it answers, under the lock. [f] answering an
   error saves nothing. *)
let update ?build ?reconcile path f =
  with_lock path (fun () ->
      let* t = load ?build ?reconcile path in
      let* t' = f t in
      save path t';
      Ok t')
