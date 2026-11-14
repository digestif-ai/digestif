(* digestif-update approve and signers propose (docs/releases.md, Approvals; docs/protocol.md,
   Approvals): an admin signs an invite or a signer-set change with the release key `sign --next`
   reads, and hands the signature to this machine's node through its local API. The node never
   holds, asks for or receives the secret half: this module reads it into memory, signs the
   document's exact bytes over its kind's domain line, and posts the signature alone. *)

let ( let* ) = Result.bind

(* THE LOCAL API. One call: a method, a path with its query, a JSON body; the status and the JSON it
   answered. A function, so the tests put an in-process node behind it. *)
type api =
  meth:string ->
  path:string ->
  body:Yojson.Safe.t option ->
  (int * Yojson.Safe.t, string) result

(* The node at [data_dir]: its log, the URL its web UI bound (Server.start records it), and a
   session minted for this command and ended with it, so nothing that opens the API outlives the
   run. *)
let with_node ~transport ~data_dir f =
  let path = Node.log_path data_dir in
  if not (Sys.file_exists path) then
    Error
      (Printf.sprintf
         "no node runs here (%s holds none); run this on the machine your node \
          runs on"
         data_dir)
  else
    let log = Log.reopen path in
    Fun.protect
      ~finally:(fun () -> Log.close log)
      (fun () ->
        match Log.get_config log "ui_url" with
        | None ->
            Error
              "the node's local API is not running; start it with digestif \
               run, then run the same command again"
        | Some base -> (
            match Local_session.mint log with
            | exception e ->
                Error
                  ("could not open a session on the node: "
                 ^ Printexc.to_string e)
            | token ->
                Fun.protect
                  ~finally:(fun () ->
                    try Local_session.end_ log token with _ -> ())
                  (fun () ->
                    let api : api =
                     fun ~meth ~path ~body ->
                      match
                        (transport : Relay_client.transport)
                          ~meth ~url:(base ^ path)
                          ~headers:(Local_session.headers token)
                          ~body:(Option.map Yojson.Safe.to_string body)
                      with
                      | Error e ->
                          Error
                            (Printf.sprintf
                               "the node did not answer at %s (%s); start it \
                                with digestif run"
                               base e)
                      | Ok { status; body } -> (
                          if String.trim body = "" then Ok (status, `Null)
                          else
                            match Yojson.Safe.from_string body with
                            | j -> Ok (status, j)
                            | exception Yojson.Json_error _ ->
                                Error
                                  (Printf.sprintf
                                     "the node answered %s %s with %d and no \
                                      JSON"
                                     meth path status))
                    in
                    f api)))

(* The first node_error's message, the way every 4xx of the local API answers. *)
let error_message ~meth ~path status (j : Yojson.Safe.t) =
  let detail =
    match j with
    | `List (`Assoc kv :: _) -> (
        match List.assoc_opt "message" kv with
        | Some (`String m) -> m
        | _ -> Yojson.Safe.to_string j)
    | `Null -> "no body"
    | j -> Yojson.Safe.to_string j
  in
  Printf.sprintf "the node answered %s %s with %d: %s" meth path status detail

(* WHAT THE NODE ANSWERS, read into the few fields this command needs. *)

type member = { identity : string; name : string }
type signer_row = { key : Keys.public_key; signed : bool }

type approval = {
  id : string;
  kind : Approval.kind;
  state : string;
  created_at : string;
  member : member option;
  guest : string option;
  added_key : Keys.public_key option;
  removed_key : Keys.public_key option;
  waiting_on : member list;
  signed_count : int;
  needed_count : int;
  signers : signer_row list;
  document : string option;  (** the document's exact bytes, decoded *)
}

(* A key of the folded signer set (GET /api/v0/signers). *)
type set_key = { set_name : string; set_key : Keys.public_key; revoked : bool }

let str name j = Release.string_field name j

let opt_str name j =
  match Release.field name j with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (Printf.sprintf "field %S must be a string" name)

let int_field name j =
  match Release.field name j with
  | Some (`Int n) -> Ok n
  | _ -> Error (Printf.sprintf "field %S must be an integer" name)

let list name j =
  match Release.field name j with
  | None | Some `Null -> Ok []
  | Some (`List l) -> Ok l
  | Some _ -> Error (Printf.sprintf "field %S must be a list" name)

let member_of_json j =
  let* identity = str "identity" j in
  let* name = str "name" j in
  Ok { identity; name }

let opt_member name j =
  match Release.field name j with
  | None | Some `Null -> Ok None
  | Some m -> Result.map Option.some (member_of_json m)

let signer_row_of_json j =
  let* key = str "key" j in
  let* signed =
    match Release.field "signed" j with
    | Some (`Bool b) -> Ok b
    | _ -> Error "field \"signed\" must be a boolean"
  in
  Ok { key; signed }

let approval_of_json j =
  let* id = str "id" j in
  let* kind_s = str "kind" j in
  let* kind =
    match Approval.kind_of_string kind_s with
    | Some k -> Ok k
    | None -> Error (Printf.sprintf "unknown approval kind %S" kind_s)
  in
  let* state = str "state" j in
  let* created_at = str "created_at" j in
  let* member = opt_member "member" j in
  let* guest = opt_str "guest" j in
  let* added_key = opt_str "added_key" j in
  let* removed_key = opt_str "removed_key" j in
  let* waiting = list "waiting_on" j in
  let* waiting_on = Release.all member_of_json waiting in
  let* signed_count = int_field "signed_count" j in
  let* needed_count = int_field "needed_count" j in
  let* rows = list "signers" j in
  let* signers = Release.all signer_row_of_json rows in
  let* document =
    let* d = opt_str "document" j in
    match d with
    | None -> Ok None
    | Some d -> (
        match B64url.decode d with
        | Ok bytes -> Ok (Some bytes)
        | Error _ -> Error "field \"document\" is not base64url")
  in
  Ok
    {
      id;
      kind;
      state;
      created_at;
      member;
      guest;
      added_key;
      removed_key;
      waiting_on;
      signed_count;
      needed_count;
      signers;
      document;
    }

let set_key_of_json j =
  let* set_key = str "key" j in
  let* set_name = str "name" j in
  let revoked =
    match Release.field "revoked" j with Some (`Bool b) -> b | _ -> false
  in
  Ok { set_name; set_key; revoked }

let get_ok (api : api) path =
  let* status, j = api ~meth:"GET" ~path ~body:None in
  if status = 200 then Ok j
  else Error (error_message ~meth:"GET" ~path status j)

let approvals ?state (api : api) =
  let path =
    "/api/v0/approvals?limit=50"
    ^ match state with Some s -> "&state=" ^ s | None -> ""
  in
  let* j = get_ok api path in
  match j with
  | `List l ->
      Result.map_error
        (fun e -> "an approval the node listed: " ^ e)
        (Release.all approval_of_json l)
  | _ -> Error ("the node answered GET " ^ path ^ " with no list")

let signer_set (api : api) =
  let* j = get_ok api "/api/v0/signers" in
  let* l = list "signers" j in
  Result.map_error
    (fun e -> "the signer set the node answered: " ^ e)
    (Release.all set_key_of_json l)

(* WHO THE APPROVAL WAITS ON. A promotion or a replacement has no document until the new key's
   holder signs first, which completes it; until then it waits on that holder alone. A promotion's
   new key is not known before then, so its holder is the one reader whose key is not in the set:
   the promoted member, the only reader who is not an admin. *)

type step =
  | Sign of string  (** the document's bytes, already complete *)
  | Complete of string  (** the document this key completes, then signs *)

let in_set ~me set = List.exists (fun k -> k.set_key = me) set

let first_signer_name (a : approval) =
  match (a.waiting_on, a.member) with
  | m :: _, _ | [], Some m -> m.name
  | [], None -> "the new key's holder"

let waiting_line (a : approval) =
  match a.waiting_on with
  | [] -> Printf.sprintf "%d of %d" a.signed_count a.needed_count
  | [ m ] ->
      Printf.sprintf "Waiting on %s · %d of %d" m.name a.signed_count
        a.needed_count
  | l ->
      Printf.sprintf "Waiting on %d · %d of %d" (List.length l) a.signed_count
        a.needed_count

(* The new signer set a promotion or a replacement names once [me] signs first: the set the node
   folded plus [me] under the member's name, or with the replaced key's entry moved to [me].
   Rendered in release-signers.json's layout; its exact bytes are what every key then signs. *)
let signers_document ~created_at (signers : Release.signer list) =
  let q s = Yojson.Safe.to_string (`String s) in
  let line (s : Release.signer) =
    Printf.sprintf "    { \"name\": %s, \"key\": %s }" (q s.name) (q s.key)
  in
  Printf.sprintf
    "{\n\
    \  \"format\": %s,\n\
    \  \"created_at\": %s,\n\
    \  \"signers\": [\n\
     %s\n\
    \  ]\n\
     }\n"
    (q Approval.signers_format)
    (q created_at)
    (String.concat ",\n" (List.map line signers))

let completed_set ~me ~set (a : approval) =
  let current =
    List.map
      (fun k -> ({ name = k.set_name; key = k.set_key } : Release.signer))
      set
  in
  let* next =
    match a.kind with
    | Approval.Promotion -> (
        match a.member with
        | None -> Error "the promotion names no member"
        | Some m -> Ok (current @ [ { Release.name = m.name; key = me } ]))
    | Approval.Replacement -> (
        match a.removed_key with
        | None -> Error "the replacement names no key to take out"
        | Some old
          when not
                 (List.exists (fun (s : Release.signer) -> s.key = old) current)
          ->
            Error
              (Printf.sprintf
                 "the key it replaces, %s, is not in the signer set" old)
        | Some old ->
            Ok
              (List.map
                 (fun (s : Release.signer) ->
                   if s.key = old then { s with key = me } else s)
                 current))
    | Approval.Invite | Approval.Removal ->
        Error "only a promotion or a replacement is completed by its new key"
  in
  match
    List.find_opt
      (fun k ->
        k.revoked
        && List.exists (fun (s : Release.signer) -> s.key = k.set_key) next)
      set
  with
  | Some k ->
      Error
        (Printf.sprintf
           "the new set would still hold %s's revoked key %s; only a removal \
            or a replacement of that key clears it"
           k.set_name k.set_key)
  | None -> Ok (signers_document ~created_at:a.created_at next)

(* What [me] does with [a], or why it does nothing. *)
let step ~me ~set (a : approval) =
  if a.state <> "waiting" then
    Error (Printf.sprintf "approval %s is %s; nothing was signed" a.id a.state)
  else
    match a.document with
    | Some bytes -> (
        match List.find_opt (fun r -> r.key = me) a.signers with
        | Some { signed = true; _ } ->
            Error
              (Printf.sprintf "your key already signed approval %s (%s)" a.id
                 (waiting_line a))
        | Some _ -> Ok (Sign bytes)
        | None ->
            Error
              (Printf.sprintf
                 "approval %s does not need your key %s; nothing was signed"
                 a.id me))
    | None -> (
        let first () =
          Error
            (Printf.sprintf "Waiting on %s; nothing was signed"
               (first_signer_name a))
        in
        match a.kind with
        | Approval.Replacement -> (
            match a.added_key with
            | Some k when k = me ->
                Result.map (fun d -> Complete d) (completed_set ~me ~set a)
            | Some _ -> first ()
            | None -> Error "the replacement names no new key")
        | Approval.Promotion ->
            if in_set ~me set then first ()
            else Result.map (fun d -> Complete d) (completed_set ~me ~set a)
        | Approval.Invite | Approval.Removal ->
            Error (Printf.sprintf "approval %s carries no document" a.id))

let waiting_on_me ~me ~set a =
  match step ~me ~set a with Ok _ -> true | Error _ -> false

(* WHAT IT SIGNS, read from the document's own bytes, never from the node's summary of them, so
   what is shown is what the signature covers. A set change's document must be the change its kind
   names and nothing more: a promotion adds one key, a removal takes one out, a replacement does
   both. *)

let admission_lines bytes =
  let* j = Release.parse_json Approval.admission_format bytes in
  let* () = Release.expect_format Approval.admission_format j in
  let guest = Option.value (Release.field "guest" j) ~default:`Null in
  let* name = str "name" guest in
  let* email = str "email" guest in
  let* role = str "role" j in
  let* circle = str "circle" j in
  let* invite_key = str "invite_key" j in
  let* subject = str "subject" j in
  let* body = str "body" j in
  Ok
    ([
       Printf.sprintf "Invite %s <%s> as %s" name email role;
       "  circle:     " ^ circle;
       "  invite key: " ^ invite_key;
       "";
       "Subject: " ^ subject;
       "";
     ]
    @ String.split_on_char '\n' body)

let set_change_lines ~set (a : approval) bytes =
  let* next = Trust_root.signers_of_string bytes in
  let keys l = List.map (fun (s : Release.signer) -> s.key) l in
  let current = List.map (fun k -> k.set_key) set in
  let added = List.filter (fun k -> not (List.mem k current)) (keys next) in
  let removed = List.filter (fun k -> not (List.mem k (keys next))) current in
  let* () =
    let n = List.length in
    let ok =
      match a.kind with
      | Approval.Promotion -> n added = 1 && n removed = 0
      | Approval.Removal -> n added = 0 && n removed = 1
      | Approval.Replacement -> n added = 1 && n removed = 1
      | Approval.Invite -> false
    in
    let named k = function None -> true | Some x -> x = k in
    let ok =
      ok
      && List.for_all (fun k -> named k a.added_key) added
      && List.for_all (fun k -> named k a.removed_key) removed
    in
    if ok then Ok ()
    else
      Error
        (Printf.sprintf
           "the document is not the %s it is filed as (it adds %d keys and \
            takes out %d); nothing was signed"
           (Approval.kind_to_string a.kind)
           (List.length added) (List.length removed))
  in
  let* () =
    let ks = keys next in
    if List.length ks < 2 then Error "the new set has fewer than two keys"
    else if List.length (List.sort_uniq compare ks) <> List.length ks then
      Error "the new set names a key twice"
    else Ok ()
  in
  let name_of k =
    match List.find_opt (fun s -> s.set_key = k) set with
    | Some s -> s.set_name
    | None -> k
  in
  Ok
    (Printf.sprintf "%s: the signer set becomes"
       (String.capitalize_ascii (Approval.kind_to_string a.kind))
     :: List.map
          (fun (s : Release.signer) ->
            Printf.sprintf "  %s %s  %s"
              (if List.mem s.key added then "+" else " ")
              s.name s.key)
          next
    @ List.map (fun k -> Printf.sprintf "  - %s  %s" (name_of k) k) removed)

let shown ~set (a : approval) bytes =
  match a.kind with
  | Approval.Invite -> admission_lines bytes
  | _ -> set_change_lines ~set a bytes

(* The signature over the kind's domain line and the document's exact bytes. *)
let signature ~secret kind bytes =
  Keys.sign secret (Release.signed_bytes ~domain:(Approval.domain kind) bytes)

let describe (a : approval) =
  let who =
    match (a.kind, a.guest, a.member) with
    | Approval.Invite, Some g, _ -> "invite " ^ g
    | Approval.Promotion, _, Some m -> m.name ^ " → admin"
    | Approval.Removal, _, Some m -> m.name ^ " → member"
    | Approval.Replacement, _, Some m -> "replace " ^ m.name ^ "'s key"
    | k, _, _ -> Approval.kind_to_string k
  in
  Printf.sprintf "%s  %s  (%s)" a.id who (waiting_line a)

(* digestif-update approve with no id: the approvals waiting on this key, each with its command. *)
let list ~(api : api) ~me ~say =
  let* waiting = approvals ~state:"waiting" api in
  let* set = signer_set api in
  match List.filter (waiting_on_me ~me ~set) waiting with
  | [] ->
      say (Printf.sprintf "no approval is waiting on your key %s" me);
      Ok ()
  | mine ->
      List.iter
        (fun a ->
          say (describe a);
          say ("  digestif-update approve " ^ a.id))
        mine;
      Ok ()

let find ~(api : api) id =
  let* waiting = approvals ~state:"waiting" api in
  match List.find_opt (fun (a : approval) -> a.id = id) waiting with
  | Some a -> Ok a
  | None -> (
      let* all = approvals api in
      match List.find_opt (fun (a : approval) -> a.id = id) all with
      | Some a -> Ok a
      | None ->
          Error
            (Printf.sprintf
               "this node reads no approval %s; run digestif-update approve \
                for the ones waiting on your key"
               id))

let affirmative s =
  match String.lowercase_ascii (String.trim s) with
  | "y" | "yes" -> true
  | _ -> false

(* digestif-update approve <id>: shown, asked once, signed, handed to the node. *)
let sign ~(api : api) ~secret ~ask ~say id =
  let me = Keys.public secret in
  let* a = find ~api id in
  let* set = signer_set api in
  let* step = step ~me ~set a in
  let bytes, completes =
    match step with Sign b -> (b, false) | Complete b -> (b, true)
  in
  let* lines = shown ~set a bytes in
  List.iter say lines;
  say "";
  if completes then
    say
      ("Your signature is this change's first: it completes the document with \
        your key " ^ me);
  if
    not
      (affirmative
         (ask (Printf.sprintf "Sign approval %s with %s? [y/N] " a.id me)))
  then (
    say "nothing was signed";
    Ok ())
  else
    let path = "/api/v0/approvals/" ^ a.id ^ "/signatures" in
    let body =
      `Assoc
        ([
           ("key", `String me);
           ("signature", `String (signature ~secret a.kind bytes));
         ]
        @
        if completes then [ ("document", `String (B64url.encode bytes)) ]
        else [])
    in
    let* status, j = api ~meth:"POST" ~path ~body:(Some body) in
    if status <> 200 then Error (error_message ~meth:"POST" ~path status j)
    else
      match approval_of_json j with
      | Ok after when after.state = "signed" ->
          say
            "signed: every signature is in, and this node posts it to the \
             circle";
          Ok ()
      | Ok after ->
          say ("signed. " ^ waiting_line after);
          Ok ()
      | Error _ ->
          say "signed";
          Ok ()

(* digestif-update signers propose --replace OLD --with NEW: the replacement filed through the
   node, which seals it to the admins; NEW signs first. *)
let propose_replacement ~(api : api) ~say ~old ~new_ =
  let* old = Keys.parse_ed25519 (String.trim old) in
  let* new_ = Keys.parse_ed25519 (String.trim new_) in
  if old = new_ then Error "--replace and --with name the same key"
  else
    let path = "/api/v0/approvals" in
    let body =
      `Assoc
        [
          ("kind", `String (Approval.kind_to_string Approval.Replacement));
          ("removed_key", `String old);
          ("added_key", `String new_);
        ]
    in
    let* status, j = api ~meth:"POST" ~path ~body:(Some body) in
    if status <> 201 then Error (error_message ~meth:"POST" ~path status j)
    else
      let* a =
        Result.map_error
          (fun e -> "the approval the node filed: " ^ e)
          (approval_of_json j)
      in
      say (Printf.sprintf "filed approval %s: replace %s with %s" a.id old new_);
      say "Your new key signs first, read by the key command or prompt:";
      say ("  digestif-update approve " ^ a.id);
      Ok ()
