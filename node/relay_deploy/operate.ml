(* Operating a relay (docs/releases.md, Who operates a relay): `digestif relay operate <url>` and
   `--remove`, the relay-deploy-token keystore entry and relay-deploy.json in the data directory,
   the token checks against Cloudflare, `digestif relay status`, and the operator test: the relay's
   newest relay message was authored by a device of this node's identity, and this node holds a
   deploy token and a deployment record for that relay's url.

   STUB: ISS-46051 ("digestif — operating a relay", row 5 of DES-45470) fills this module. Until it
   lands no node operates a relay, so the deploy pass (Deploy) never finds one to deploy. *)

let not_built = "relay operation is not built yet (ISS-46051)"

(* The relays this node operates, by url. *)
let operated (_ : Node.t) (_ : Fold.t) : string list = []

let operate (_ : Node.t) ~url:(_ : string) : (unit, string) result =
  Error not_built

let remove (_ : Node.t) ~url:(_ : string) : (unit, string) result =
  Error not_built

(* What `digestif relay status` prints: the record, the newest relay release, the deployed
   version, a pending step and its retry time, and refused versions, never the token. *)
let status (_ : Node.t) ~(releases : Digestif_update.Circle_relay_release.t) :
    string list =
  let newest =
    match releases.newest with
    | Some r ->
        "newest relay release\t"
        ^ Digestif_update.Version.to_string r.doc.relay_version
    | None -> "newest relay release\tnone announced"
  in
  [ newest; "operated relays\t" ^ not_built ]
