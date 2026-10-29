(* What a node may install, decided from what it trusts and what the channel serves. Pure: no
   network, no disk. docs/releases.md is the prose version of every rule here. *)

open Release

type trust = {
  signers : signer list;
      (** The release signer set: every one of them signs every release. *)
  revoked : Keys.public_key list;
      (** Keys a current signer revoked; never trusted again. *)
}

type refusal =
  | No_signers
  | Missing_signatures of string list
      (** Names of current signers whose signature is absent. *)
  | Halted_by_revocation of string list
      (** Current signers revoked; only a signer-set change goes. *)
  | Bad_signer_set of string
  | Unproven_new_signers of string list
      (** New signers whose signature is absent. *)

let refusal_to_string = function
  | No_signers ->
      "no release signers are configured, so nothing can be installed"
  | Missing_signatures names -> "not signed by " ^ String.concat " and " names
  | Halted_by_revocation names ->
      "updates are halted: the release key of "
      ^ String.concat " and " names
      ^ " is revoked, and only a release replacing the signer set can be \
         installed"
  | Bad_signer_set why -> "the signer set it names is refused: " ^ why
  | Unproven_new_signers names ->
      "the new signer set is not signed by its own new keys: "
      ^ String.concat " and " names

let is_revoked trust key = List.mem key trust.revoked

(* A revocation is honored when any CURRENT signer signed it, revoked or not: a signer whose key
   leaked still holds it, and either signer can halt updates by withholding a signature anyway, so a
   revocation grants nobody more than they already had. *)
let apply_revocations trust (revocations : revocation signed list) =
  let rec fixpoint trust =
    let current = List.map (fun (s : signer) -> s.key) trust.signers in
    let next =
      List.fold_left
        (fun trust r ->
          if is_revoked trust r.doc.revoked_key then trust
          else
            let by =
              valid_signers ~domain:revocation_domain r.bytes r.signatures
            in
            if List.exists (fun k -> List.mem k current) by then
              { trust with revoked = trust.revoked @ [ r.doc.revoked_key ] }
            else trust)
        trust revocations
    in
    if List.length next.revoked = List.length trust.revoked then trust
    else fixpoint next
  in
  fixpoint trust

let check_signer_set trust (signers : signer list) =
  let keys = List.map (fun (s : signer) -> s.key) signers in
  let distinct = List.sort_uniq String.compare keys in
  if List.length signers < 2 then
    Error
      (Bad_signer_set
         "a signer set has at least two signers, so no one person can release")
  else if List.length distinct <> List.length keys then
    Error (Bad_signer_set "a key appears twice")
  else
    match List.filter (is_revoked trust) keys with
    | [] -> Ok ()
    | bad ->
        Error
          (Bad_signer_set ("it names a revoked key: " ^ String.concat ", " bad))

(* Whether [release] may be installed under [trust], and the trust that follows from it. *)
let check trust (release : manifest signed) =
  if trust.signers = [] then Error No_signers
  else
    let valid =
      valid_signers ~domain:release_domain release.bytes release.signatures
    in
    let missing =
      List.filter (fun s -> not (List.mem s.key valid)) trust.signers
    in
    if missing <> [] then
      Error (Missing_signatures (List.map (fun s -> s.name) missing))
    else
      match release.doc.signers with
      | None -> (
          match List.filter (fun s -> is_revoked trust s.key) trust.signers with
          | [] -> Ok trust
          | halted ->
              Error (Halted_by_revocation (List.map (fun s -> s.name) halted)))
      | Some next -> (
          match check_signer_set trust next with
          | Error e -> Error e
          | Ok () -> (
              match List.filter (fun s -> not (List.mem s.key valid)) next with
              | [] -> Ok { trust with signers = next }
              | unproven ->
                  Error
                    (Unproven_new_signers (List.map (fun s -> s.name) unproven))
              ))

type skipped = { skipped_version : Version.t; reason : string }

type plan = {
  install : manifest signed option;  (** The release to install now, if any. *)
  artifact : artifact option;  (** Its artifact for this platform. *)
  trust : trust;
      (** The trust after every accepted release; persisted whether or not
          installing. *)
  skipped : skipped list;
      (** Releases newer than the installed one that were refused, and why. *)
  pinned_at : Version.t option;
}

(* Walk every release newer than [installed] in version order, adopting each signer-set change both
   current signers signed, and choose the release to install: the pinned version when [pin] is set,
   the newest accepted release otherwise. Signer-set changes are adopted past a pin, since adopting
   one installs no code and a pinned node must still verify the release it is unpinned onto. *)
let plan ~installed ~pin ~platform trust ~revocations
    (releases : manifest signed list) =
  let trust = apply_revocations trust revocations in
  let newer =
    List.filter (fun r -> Version.compare r.doc.version installed > 0) releases
    |> List.stable_sort (fun a b -> Version.compare a.doc.version b.doc.version)
  in
  let duplicated v =
    List.length (List.filter (fun r -> Version.equal r.doc.version v) newer) > 1
  in
  let skip r reason acc_skipped =
    { skipped_version = r.doc.version; reason } :: acc_skipped
  in
  let wanted r =
    match pin with None -> true | Some p -> Version.equal r.doc.version p
  in
  let trust, chosen, skipped =
    List.fold_left
      (fun (trust, chosen, skipped) r ->
        if duplicated r.doc.version then
          ( trust,
            chosen,
            skip r "the channel serves two manifests for this version" skipped
          )
        else
          match check trust r with
          | Error e -> (trust, chosen, skip r (refusal_to_string e) skipped)
          | Ok next -> (
              let next = apply_revocations next revocations in
              if not (wanted r) then (next, chosen, skipped)
              else
                match
                  List.find_opt (fun a -> a.platform = platform) r.doc.artifacts
                with
                | None ->
                    ( next,
                      chosen,
                      skip r ("it has no artifact for " ^ platform) skipped )
                | Some a -> (next, Some (r, a), skipped)))
      (trust, None, []) newer
  in
  {
    install = Option.map fst chosen;
    artifact = Option.map snd chosen;
    trust;
    skipped = List.rev skipped;
    pinned_at = pin;
  }
