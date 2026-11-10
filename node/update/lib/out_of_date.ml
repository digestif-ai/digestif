(* `sign --next` SAYS WHEN THE TOOL IS OUT OF DATE (docs/releases.md, Signing a release). A signer
   signs with the digestif-update on PATH, a link to their node's good release that the node's
   updater moves (Cli_links), so the node keeps the tool current and this module replaces nothing:
   when the newest node release that is not a draft is newer than the running binary, it says so,
   and how that release reaches the signer, and the run goes on.

   The release channel a node reads (Feed) decides which published versions count: a version a
   signer recalled is never offered, and a revocation applies to the signer set the recall is
   judged against, as both do on a node. Nothing here stops the run: GitHub or the channel not
   answering says nothing and the signing goes on. *)

let ( let* ) = Result.bind

type decision =
  | Current  (** Nothing published is newer than the running binary. *)
  | Untagged
      (** The running binary is a build of no tag (0.0.0), a developer's own. *)
  | Newer of Sign_next.draft  (** This published release is newer. *)

let untagged = { Version.major = 0; minor = 0; patch = 0 }

(* The recall of [r] that counts under [trust], as a node reads it (Policy.recall_of). *)
let recall_of ~trust ~recalls (r : Sign_next.draft) =
  Policy.recall_of trust recalls r.version

(* What to say, from the node releases GitHub lists and the running binary's version: the newest
   release that is not a draft and that no counting recall names. *)
let decide ~trust ~recalls ~running (releases : Sign_next.draft list) =
  match
    Sign_next.newest
      (List.filter
         (fun (r : Sign_next.draft) ->
           (not r.draft) && recall_of ~trust ~recalls r = None)
         releases)
  with
  | None -> Current
  | Some p when Version.compare p.version running <= 0 -> Current
  | Some _ when Version.equal running untagged -> Untagged
  | Some p -> Newer p

(* Whether [self], every link resolved, is a node's own binary: <data dir>/releases/<version>/bin/
   digestif-update (Layout). Anything else (a file fetched from a release by hand, a copy) is one
   no node moves. *)
let in_a_node self =
  let real = try Unix.realpath self with Unix.Unix_error _ -> self in
  let bin = Filename.dirname real in
  Filename.basename bin = "bin"
  && Filename.basename (Filename.dirname (Filename.dirname bin)) = "releases"

let install_line = "curl -fsSL https://digestif.io/install.sh | sh"

(* The line a newer published release leaves, by where the running binary lives. *)
let newer_line ~running ~self (p : Sign_next.draft) =
  let running = Version.to_string running in
  if in_a_node self then
    Printf.sprintf
      "%s is published and this digestif-update is %s. Your node takes it at \
       its next update check (digestif update apply takes it now), and the \
       digestif-update on PATH follows it."
      p.tag running
  else
    Printf.sprintf
      "%s is published and this digestif-update, %s, is %s, which no node \
       keeps current. Install a node with `%s` and sign with the \
       digestif-update it puts on PATH (docs/releases.md, Signing a release)."
      p.tag running self install_line

(* Every newer published version a counting recall names, said so the signer knows why it is not
   offered. *)
let say_recalled ~trust ~recalls ~running ~say releases =
  List.iter
    (fun (r : Sign_next.draft) ->
      if (not r.draft) && Version.compare r.version running > 0 then
        match recall_of ~trust ~recalls r with
        | Some recall ->
            say (Policy.recalled_line recall ^ " It is not offered.")
        | None -> ())
    releases

(* What `sign --next` does before anything else. [channel] reads the release channel nodes read
   (Feed.read). It changes nothing and never stops the run. *)
let run ~gh ~repo ~signers ~channel ~running ~self ~say () =
  let outcome =
    let* listed = gh [ "api"; Sign_next.releases_path repo ] in
    let* releases = Sign_next.releases_of_string listed in
    let* (feed : Feed.t) = channel () in
    let trust =
      Policy.apply_revocations { Policy.signers; revoked = [] } feed.revocations
    in
    let recalls = feed.recalls in
    say_recalled ~trust ~recalls ~running ~say releases;
    Ok (decide ~trust ~recalls ~running releases)
  in
  match outcome with
  | Ok (Newer p) -> say (newer_line ~running ~self p)
  | Ok (Current | Untagged) | Error _ -> ()
