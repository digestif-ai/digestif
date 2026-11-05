(* A relay release announced on the circle as a relay_release message (docs/protocol.md,
   relay_release; docs/releases.md, Relay releases). The body is the relay manifest, byte for byte in
   base64url, and the signatures from its .sig.json, as for release_revocation and release_recall.

   Core's admission fold (Fold.apply_release_document) checks only an admitted, unrevoked author and
   the body's two fields, as a relay does: neither knows the release signer set. What an
   announcement means is decided here, against the node's own signer set, on every sync, and
   nothing is stored but the verdict per version this call returns:

   - An announcement counts when every key of the current, unrevoked signer set signed
     DIGESTIF-RELAY-RELEASE-V0 and the document, and the document parses as
     digestif-relay-release-v1. One that does not is a fault shown to the member.
   - While a revoked key is in the signer set, no announcement counts.
   - The newest relay release is the counting announcement with the highest version. Order is by
     version alone, never created_at or relay order, so a replayed old announcement changes
     nothing.
   - Two counting announcements of one version with different documents are a fault and neither
     counts.
   - The same document announced twice is one announcement.

   An announcement carries no instruction to deploy: every node folds it, an operator's node acts
   on it (Relay_deploy), and every node judges from it whether a relay is behind. *)

open Release

let kind = "relay_release"
let to_body (r : relay_manifest signed) : Yojson.Safe.t = body_of_signed r

(* The relay manifest a body carries, parsed, and its signatures read but not yet checked. *)
let of_body (json : Yojson.Safe.t) : (relay_manifest signed, string) result =
  signed_of_body relay_manifest_of_string json

(* One announcement as the log holds it: the envelope's hash names it in a fault. *)
type announcement = {
  hash : string;
  author : string;
  seq : int;
  body : Yojson.Safe.t;
}

type fault =
  | Unreadable of { at : announcement; why : string }
      (** The body's document is not base64url or not a relay manifest. *)
  | Not_counted of {
      at : announcement;
      version : Version.t;
      refusal : Policy.refusal;
    }  (** Not signed by every current signer, or the set is halted. *)
  | Conflicting of { version : Version.t; hashes : string list }
      (** Two documents signed under one version: neither counts. *)

let fault_detail = function
  | Unreadable { at; why } -> at.hash ^ " " ^ why
  | Not_counted { at; version; refusal } ->
      Printf.sprintf "%s relay release %s does not count: %s" at.hash
        (Version.to_string version)
        (Policy.refusal_to_string refusal)
  | Conflicting { version; hashes } ->
      Printf.sprintf
        "%s relay release %s is announced with two different manifests, so \
         neither counts"
        (String.concat " " hashes)
        (Version.to_string version)

type t = {
  counted : relay_manifest signed list;
      (** Every relay release that counts, one per version, oldest first. *)
  newest : relay_manifest signed option;
  faults : fault list;
}

let counts t version =
  List.exists
    (fun (r : relay_manifest signed) ->
      Version.equal r.doc.relay_version version)
    t.counted

(* What [announcements] mean under [trust]. Pure: the same announcements and the same trust give
   the same answer whatever order they arrive in. *)
let fold (trust : Policy.trust) (announcements : announcement list) : t =
  let read, faults =
    List.fold_left
      (fun (read, faults) at ->
        match of_body at.body with
        | Error why -> (read, Unreadable { at; why } :: faults)
        | Ok r -> (
            match Policy.check_relay trust r with
            | Ok () -> ((at, r) :: read, faults)
            | Error refusal ->
                ( read,
                  Not_counted { at; version = r.doc.relay_version; refusal }
                  :: faults )))
      ([], []) announcements
  in
  let read = List.rev read and faults = List.rev faults in
  (* One entry per version: the documents its counting announcements carry, deduplicated. *)
  let by_version =
    List.fold_left
      (fun acc ((at : announcement), (r : relay_manifest signed)) ->
        let v = r.doc.relay_version in
        match List.partition (fun (w, _) -> Version.equal w v) acc with
        | [ (_, docs) ], rest ->
            let docs =
              if List.exists (fun (b, _, _) -> b = r.bytes) docs then docs
              else docs @ [ (r.bytes, r, at.hash) ]
            in
            (v, docs) :: rest
        | _, rest -> (v, [ (r.bytes, r, at.hash) ]) :: rest)
      [] read
  in
  let counted, conflicts =
    List.fold_left
      (fun (counted, conflicts) (v, docs) ->
        match docs with
        | [ (_, r, _) ] -> (r :: counted, conflicts)
        | _ ->
            ( counted,
              Conflicting
                { version = v; hashes = List.map (fun (_, _, h) -> h) docs }
              :: conflicts ))
      ([], []) by_version
  in
  let counted =
    List.sort
      (fun (a : relay_manifest signed) (b : relay_manifest signed) ->
        Version.compare a.doc.relay_version b.doc.relay_version)
      counted
  in
  let conflicts =
    List.sort
      (fun a b ->
        match (a, b) with
        | Conflicting a, Conflicting b -> Version.compare a.version b.version
        | _ -> 0)
      conflicts
  in
  {
    counted;
    newest = (match List.rev counted with r :: _ -> Some r | [] -> None);
    faults = faults @ conflicts;
  }

(* Every relay_release the admission fold applied, in the order the log holds them. *)
let applied (node : Node.t) (fold : Fold.t) : announcement list =
  let applied = Hashtbl.create 64 in
  List.iter (fun h -> Hashtbl.replace applied h ()) fold.applied;
  List.filter_map
    (fun (row : Log.row) ->
      if not (Hashtbl.mem applied row.hash) then None
      else
        Some
          {
            hash = row.hash;
            author = row.signed.envelope.author;
            seq = row.signed.envelope.seq;
            body = Option.value row.signed.body ~default:`Null;
          })
    (Log.of_kind node.log kind)

(* The node's half, run after every sync: fold the circle's announcements against the signer set
   the update state at [state_path] holds, and record each fault for the member. A fault on one
   announcement is recorded against it; a conflict, which names several, against each. *)
let from_circle ~state_path (node : Node.t) (fold_ : Fold.t) :
    (t, string) result =
  match applied node fold_ with
  | [] -> Ok { counted = []; newest = None; faults = [] }
  | announcements ->
      Result.map
        (fun (state : State.t) ->
          let t = fold state.trust announcements in
          let record (at : announcement) detail =
            Log.add_fault node.log ~kind ~author:at.author ~seq:at.seq ~detail
          in
          List.iter
            (fun f ->
              match f with
              | Unreadable { at; _ } | Not_counted { at; _ } ->
                  record at (fault_detail f)
              | Conflicting { hashes; _ } ->
                  List.iter
                    (fun (at : announcement) ->
                      if List.mem at.hash hashes then record at (fault_detail f))
                    announcements)
            t.faults;
          t)
        (State.load state_path)
