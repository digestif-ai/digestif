(* The deploy pass of `digestif run` (docs/releases.md, The deploy step): due when this node
   operates a relay, folds a newest relay release newer than the version the relay reports and not
   refused, and no node switch is on trial. Verify the bundle, apply the migrations the database
   lacks through the D1 API, upload the assets and the module with keep_bindings, deploy, check the
   relay's health, and keep the version or roll back; a step failing before the deploy is pending
   and retried on the update pass's backoff.

   STUB: ISS-46054 ("digestif — the deploy pass", row 6 of DES-45470) fills this module, its pass
   and its digest lines. Until then the pass is never due. *)

type outcome =
  | Not_due
  | Deployed of { url : string; version : Digestif_update.Version.t }
  | Rolled_back of {
      url : string;
      version : Digestif_update.Version.t;
      to_ : Digestif_update.Version.t;
      why : string;
    }
  | Pending of { url : string; why : string; retry_at : float }

let outcome_to_string = function
  | Not_due -> "no relay deploy is due"
  | Deployed { url; version } ->
      Printf.sprintf "deployed relay %s to %s"
        (Digestif_update.Version.to_string version)
        url
  | Rolled_back { url; version; to_; why } ->
      Printf.sprintf
        "relay %s failed its health check on %s (%s); rolled back to %s"
        (Digestif_update.Version.to_string version)
        url why
        (Digestif_update.Version.to_string to_)
  | Pending { url; why; _ } ->
      Printf.sprintf "the deploy to %s is pending: %s" url why

(* One pass, run by `digestif run` after each sync with the relay releases that sync folded. *)
let pass ~dir:(_ : string) (_ : Node.t)
    ~releases:(_ : Digestif_update.Circle_relay_release.t) ~now:(_ : float) :
    outcome list =
  []

(* The digest's deploy lines: what this node deployed or why it rolled back, and a failed
   rollback, which leads the digest. *)
let digest_lines (_ : Node.t) ~now:(_ : float) : Line.t list = []
