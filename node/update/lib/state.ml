(* What a node has installed and whom it trusts to sign the next release, kept in one JSON file.
   Written atomically, so a crash leaves the old state or the new one. *)

open Release

(* A release this node will not take again: its self-test failed, or it did not report healthy
   after the switch and the supervisor moved back (docs/releases.md, Switching). *)
type refused = { refused_version : Version.t; why : string }

(* A release the node chose and could not stage yet (a download that broke, Node.js missing). The
   pass that finds it due tries again; until then the node keeps what it runs. *)
type pending = {
  pending_version : Version.t;
  cause : string;
  attempts : int;
  due_at : float;
}

type t = {
  installed : Version.t;
      (** The version that last reported healthy after a switch: what newer-only
          compares to. *)
  trust : Policy.trust;
  pin : Version.t option;
  refused : refused list;
  pending : pending option;
}

let ( let* ) = Result.bind

let initial () =
  {
    installed = Trust_root.version ();
    trust = { signers = Trust_root.signers (); revoked = [] };
    pin = None;
    refused = [];
    pending = None;
  }

let is_refused t v =
  List.exists (fun r -> Version.equal r.refused_version v) t.refused

let refuse t v why =
  if is_refused t v then t
  else { t with refused = t.refused @ [ { refused_version = v; why } ] }

(* The build's signer set, adopted when it names more signers than the stored set and none of them
   is revoked. A node first written by a build that knew one signer otherwise stays on that set
   forever and installs nothing. This does not weaken the two-signer rule: the binary that holds
   this set is one the member built or installed, so it is already their trust root, and anyone who
   could change the set it embeds could change the code that checks signatures just as well. *)
let reconcile_signers ~build (trust : Policy.trust) =
  let revoked (s : signer) = List.mem s.key trust.revoked in
  if
    List.length build > List.length trust.signers
    && not (List.exists revoked build)
  then { trust with signers = build }
  else trust

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
                 ] );
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
        Ok (Some { pending_version; cause; attempts; due_at })
  in
  Ok { installed; trust = { signers; revoked }; pin; refused; pending }

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_atomic path contents =
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    0o600 tmp (fun oc -> Out_channel.output_string oc contents);
  Unix.rename tmp path

(* The state at [path], or the build's own state when the file does not exist yet. A file that
   exists and does not parse is an error, never silently replaced by the build's trust root. A
   stored signer set smaller than the build's reaches the build's ([reconcile_signers]). *)
let load ?(build = Trust_root.signers ()) path =
  if Sys.file_exists path then
    match of_string (read_file path) with
    | Ok t -> Ok { t with trust = reconcile_signers ~build t.trust }
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
