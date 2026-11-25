(* THE SIGNING JOB (docs/releases.md, The signing job; design DIG-181, "Where the key lives"): the
   launchd job on a signer's Mac that signs exactly the node or relay manifest a decision approved.
   It holds GET /digestif/signer/decisions open on idempotent with the signer's token ({!fetch}),
   a long-poll answered with every open decision on connect and again the moment one is recorded
   or answered, and acts on each answer ({!act}): a decision whose act is sign has its draft's
   manifest.json matched against the decision's manifest_sha256, the integrity check repeated
   (exactly what `sign --next` refuses to offer a version without, {!Sign_next.show} and
   {!Sign_next.show_relay}'s problems, which no answer overrides; never the history check), and
   only then signed and uploaded with the signer's own gh login. Drop and wait sign nothing.

   Nothing re-reads on a timer: the next request goes out as soon as an answer comes back, with
   the answer's seen, and a request that fails is retried after a backoff, reading every open
   decision again as a connect does. A 401 ends the job: the token is unknown or revoked. *)

let ( let* ) = Result.bind

(* One decision, as the stream answers it (spec digestif-signers, digestif_signer_decision). *)

type line = Node | Relay
type act = Sign | Drop | Wait

type decision = {
  id : string;
  line : line;
  version : string;
  tag : string;
  manifest_sha256 : string option;
      (** 64 lowercase hex: the only manifest a sign approves. *)
  act : act;
  call : string;
  reasons : string list;
}

type answer = { seen : string; decisions : decision list }

let str k json =
  match Release.field k json with Some (`String s) -> Some s | _ -> None

let decision_of_json json =
  let need k =
    match str k json with
    | Some s -> Ok s
    | None -> Error (Printf.sprintf "a decision without %S" k)
  in
  let* id = need "id" in
  let* line =
    match str "line" json with
    | Some "node" -> Ok Node
    | Some "relay" -> Ok Relay
    | Some l ->
        Error
          (Printf.sprintf "decision %s: line %S is neither node nor relay" id l)
    | None -> Error (Printf.sprintf "decision %s has no line" id)
  in
  let* version = need "version" in
  let* tag = need "tag" in
  let* call = need "call" in
  (* An act this binary does not know is never sign. *)
  let act =
    match str "act" json with
    | Some "sign" -> Sign
    | Some "drop" -> Drop
    | _ -> Wait
  in
  let reasons =
    match Release.field "reasons" json with
    | Some (`List l) ->
        List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  Ok
    {
      id;
      line;
      version;
      tag;
      manifest_sha256 =
        Option.map String.lowercase_ascii (str "manifest_sha256" json);
      act;
      call;
      reasons;
    }

let answer_of_string bytes =
  let* json = Release.parse_json "the decisions answer" bytes in
  let* seen =
    match str "seen" json with
    | Some s -> Ok s
    | None -> Error "the decisions answer has no seen"
  in
  let* decisions =
    match Release.field "decisions" json with
    | Some (`List l) -> Release.all decision_of_json l
    | _ -> Error "the decisions answer has no decisions list"
  in
  Ok { seen; decisions }

(* THE REQUEST. *)

let default_api = "https://api.idempotent.io"

(* How long platform holds a request, in seconds: its cap, under the ingress idle timeout. *)
let wait = 25

let percent_encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let decisions_url ~api ~seen =
  Printf.sprintf "%s/digestif/signer/decisions?wait=%d%s" api wait
    (match seen with None -> "" | Some s -> "&seen=" ^ percent_encode s)

(* What one request came to. *)
type fetched =
  | Answered of answer
  | Unauthorized  (** 401: the token is unknown or revoked. *)
  | Failed of string  (** Anything else: retried after a backoff. *)

(* An HTTP GET with the token as its bearer: the status and body, or why there is none. *)
type http = token:string -> string -> (int * string, string) result

(* curl, the token handed over on stdin as a config line (-K -) so it is never in an argument
   list another process can read. *)
let curl : http =
 fun ~token url ->
  let config = Printf.sprintf "header = \"Authorization: Bearer %s\"\n" token in
  match
    Proc.run ~stdin:config
      ~timeout:(float_of_int (wait + 30))
      [|
        "curl";
        "-sS";
        "--proto";
        "=https,http";
        "--proto-redir";
        "=https";
        "--connect-timeout";
        "10";
        "--max-time";
        string_of_int (wait + 20);
        "-K";
        "-";
        "-w";
        "\n%{http_code}";
        "--";
        url;
      |]
  with
  | Error e -> Error ("curl: " ^ e)
  | Ok { code = 0; stdout; _ } -> (
      match String.rindex_opt stdout '\n' with
      | None -> Error "curl: no status"
      | Some i -> (
          match
            int_of_string_opt
              (String.sub stdout (i + 1) (String.length stdout - i - 1))
          with
          | Some status -> Ok (status, String.sub stdout 0 i)
          | None -> Error "curl: no status"))
  | Ok { code; stderr; _ } ->
      Error (Printf.sprintf "curl exited %d: %s" code (String.trim stderr))

let fetch ~(http : http) ~api ~token ~seen =
  match http ~token (decisions_url ~api ~seen) with
  | Error e -> Failed e
  | Ok (401, _) -> Unauthorized
  | Ok (200, body) -> (
      match answer_of_string body with
      | Ok a -> Answered a
      | Error e -> Failed e)
  | Ok (status, body) ->
      Failed
        (Printf.sprintf "GET /digestif/signer/decisions answered %d: %s" status
           (String.trim body))

(* ACTING ON AN ANSWER. *)

type outcome =
  | Signed of string  (** The tag, signed and uploaded. *)
  | Already of string
      (** The tag's draft already carries this signer's signature. *)
  | Published of string  (** The tag is no draft any more: nothing to sign. *)
  | Refused of string * string  (** The tag, and why nothing was signed. *)

let outcome_line = function
  | Signed tag -> Printf.sprintf "%s: signed and uploaded." tag
  | Already tag -> Printf.sprintf "%s: already carries your signature." tag
  | Published tag ->
      Printf.sprintf "%s: no longer a draft; nothing to sign." tag
  | Refused (tag, why) -> Printf.sprintf "%s: NOT SIGNED: %s" tag why

(* Whether an outcome settles its decision for the rest of the job's life: a refusal does not, so
   the next answer that carries the decision checks it again. *)
let settles = function
  | Signed _ | Already _ | Published _ -> true
  | Refused _ -> false

(* What the job needs to sign, as `sign --next` has it. *)
type env = {
  gh : string list -> (string, string) result;
  git : string list -> (string, string) result;
  clone : string;
  signers : Release.signer list;
  config : Sign_next.config;
  read_key : unit -> (string, string) result;
  tmp : string;
  relay : Sign_next.relay;
  cache : Attestation.cache;
  say : string -> unit;
}

let line_name = function Node -> "node" | Relay -> "relay"

(* The draft's manifest.json bytes, refused unless their sha256 is the one the decision approved. *)
let approved_manifest (env : env) (d : decision) (r : Sign_next.draft) =
  match d.manifest_sha256 with
  | None -> Error "the decision names no manifest sha256"
  | Some approved ->
      let* bytes =
        Result.map_error
          (fun e -> "its manifest.json could not be read: " ^ e)
          (Sign_next.fetch_manifest ~gh:env.gh ~repo:env.config.repo r)
      in
      let got = Attestation.hex (Keys.hash_of_bytes bytes) in
      if got = Attestation.hex approved then Ok bytes
      else
        Error
          (Printf.sprintf
             "the draft's manifest.json is sha256 %s, not the %s the decision \
              approved"
             got approved)

let integrity = function
  | [] -> Ok ()
  | problems ->
      Error
        ("the integrity check failed (nothing ties these files to the tag's \
          build): "
        ^ String.concat "; " problems)

(* Sign one node draft the decision approved: the manifest matched, the integrity check passed,
   then signed and uploaded. *)
let sign_node (env : env) ~attest ~releases (d : decision) (r : Sign_next.draft)
    =
  let* bytes = approved_manifest env d r in
  let* m = Sign_next.node_manifest r bytes in
  let* shown, node_bytes =
    Sign_next.show ~gh:env.gh ~attest ~git:env.git ~clone:env.clone ~tmp:env.tmp
      ~signers:env.signers ~repo:env.config.repo ~releases r m
  in
  let* () = integrity shown.problems in
  let* signed =
    Sign_next.sign_node ~signers:env.signers ~config:env.config
      ~read_key:env.read_key ~tmp:env.tmp
      { Sign_next.node = shown; node_bytes }
  in
  let* _ =
    Sign_next.upload_signed ~gh:env.gh ~config:env.config ~say:env.say
      ~time:(fun _ f -> f ())
      [ signed ]
  in
  Ok
    (match snd (snd signed) with
    | None -> Already d.tag
    | Some _ -> Signed d.tag)

(* Sign one relay draft the same way; a signature that completes the signer set publishes it, as
   `sign --next` does ({!Sign_next.settle_relays}). *)
let sign_relay (env : env) ~attest ~releases (d : decision)
    (r : Sign_next.draft) =
  let* bytes = approved_manifest env d r in
  let downloaded (x : Sign_next.draft) =
    let* b =
      if x.tag = r.tag then Ok bytes
      else Sign_next.fetch_manifest ~gh:env.gh ~repo:env.config.repo x
    in
    Sign_next.relay_manifest_of x b
  in
  let* shown, relay_bytes =
    Sign_next.show_relay ~gh:env.gh ~attest ~git:env.git ~clone:env.clone
      ~tmp:env.tmp ~signers:env.signers ~repo:env.config.repo ~relays:None
      ~releases ~downloaded r
  in
  let* () = integrity shown.relay_problems in
  let v = { Sign_next.relay = shown; relay_bytes } in
  let* signed =
    Sign_next.sign_relay ~signers:env.signers ~config:env.config
      ~read_key:env.read_key ~tmp:env.tmp v
  in
  let* mes =
    Sign_next.upload_signed ~gh:env.gh ~config:env.config ~say:env.say
      ~time:(fun _ f -> f ())
      [ signed ]
  in
  let* () =
    Sign_next.settle_relays ~gh:env.gh ~signers:env.signers ~config:env.config
      ~say:env.say ~relay:env.relay ~me:mes
      ~waiting:(Sign_next.waiting_all releases)
      [ v ]
  in
  Ok
    (match snd (snd signed) with
    | None -> Already d.tag
    | Some _ -> Signed d.tag)

(* The decisions of an answer this job signs: act sign, a manifest named, and not settled by an
   earlier answer ([settled] holds each settled decision's id and manifest sha256). *)
let to_sign ~settled decisions =
  List.filter
    (fun d ->
      d.act = Sign && d.manifest_sha256 <> None
      && not (List.mem (d.id, d.manifest_sha256) settled))
    decisions

(* ACT ON ONE ANSWER: every decision to sign, each from one listing of the releases and one fetch
   of the clone; a decision that fails is said and the rest go on. The outcome of each, in order. *)
let act (env : env) ~settled decisions =
  match to_sign ~settled decisions with
  | [] -> []
  | wanted -> (
      let listed = env.gh [ "api"; Sign_next.releases_path env.config.repo ] in
      let synced =
        Sign_next.sync_clone ~git:env.git ~say:env.say ~repo:env.config.repo
          ~clone:env.clone
      in
      match (listed, synced) with
      | Error e, _ | _, Error e ->
          List.map (fun d -> (d, Refused (d.tag, e))) wanted
      | Ok listed, Ok () ->
          let attest =
            {
              Sign_next.trusted_root =
                Sign_next.trusted_root_file ~gh:env.gh ~tmp:env.tmp;
              cache = env.cache;
            }
          in
          let releases_of = function
            | Node -> Sign_next.releases_of_string listed
            | Relay -> Sign_next.relay_releases_of_string listed
          in
          List.map
            (fun d ->
              let outcome =
                match releases_of d.line with
                | Error e -> Refused (d.tag, e)
                | Ok releases -> (
                    match
                      List.find_opt
                        (fun (r : Sign_next.draft) -> r.tag = d.tag)
                        releases
                    with
                    | None ->
                        Refused
                          ( d.tag,
                            Printf.sprintf "no %s release %s on %s"
                              (line_name d.line) d.tag env.config.repo )
                    | Some r when not r.draft -> Published d.tag
                    | Some r when Sign_next.mine_of env.config r ->
                        Already d.tag
                    | Some r -> (
                        let signed =
                          match d.line with
                          | Node -> sign_node env ~attest ~releases d r
                          | Relay -> sign_relay env ~attest ~releases d r
                        in
                        match signed with
                        | Ok o -> o
                        | Error e -> Refused (d.tag, e)))
              in
              env.say (outcome_line outcome);
              (d, outcome))
            wanted)

(* One line per decision whose act this job has not said yet, so the log shows what it waits on. *)
let describe d =
  Printf.sprintf "%s %s (%s): %s, call %s%s" (line_name d.line) d.version d.tag
    (match d.act with
    | Sign -> "sign"
    | Drop -> "drop, never signed"
    | Wait -> "wait, for Mike's answer")
    d.call
    (match d.reasons with [] -> "" | l -> " (" ^ String.concat "; " l ^ ")")

(* THE LOOP. [fetch] makes one request; [act] acts on the decisions of an answer and answers the
   outcome of each; [sleep] waits out a backoff. [rounds] bounds the requests, for a single read
   (`signer run --once`) and for tests; None runs until the token is refused. *)
let run ~fetch ~act ~sleep ~say ?rounds () =
  let settled = ref [] in
  let said = ref [] in
  let max_backoff = 300. in
  let rec go ~seen ~backoff ~left =
    if left = Some 0 then Ok ()
    else
      let left = Option.map pred left in
      match fetch ~seen with
      | Unauthorized ->
          Error
            "idempotent refused the signer token (401): it is unknown or \
             revoked. Issue a new one on the signer's page and run \
             digestif-update signer install with it."
      | Failed e ->
          say
            (Printf.sprintf
               "The decision stream failed: %s; reading again in %.0fs." e
               backoff);
          sleep backoff;
          go ~seen:None ~backoff:(Float.min max_backoff (backoff *. 2.)) ~left
      | Answered a ->
          List.iter
            (fun d ->
              if not (List.mem (d.id, d.act) !said) then (
                said := (d.id, d.act) :: !said;
                say (describe d)))
            a.decisions;
          List.iter
            (fun (d, o) ->
              if settles o then settled := (d.id, d.manifest_sha256) :: !settled)
            (act ~settled:!settled a.decisions);
          go ~seen:(Some a.seen) ~backoff:1. ~left
  in
  go ~seen:None ~backoff:1. ~left:rounds

(* INSTALLING THE SIGNING JOB (docs/releases.md, The signing job). *)

(* Where the pinned copies live: ~/.digestif/signer, one file per version, none ever replaced. *)
let signer_dir () =
  Filename.concat (Filename.concat (Sys.getenv "HOME") ".digestif") "signer"

let pinned_path ~version =
  Filename.concat (signer_dir ()) ("digestif-update-" ^ version)

let log_path () = Filename.concat (signer_dir ()) "signer.log"
let label = "io.digestif.signer"

let plist_path () =
  Filename.concat
    (Filename.concat (Sys.getenv "HOME") "Library/LaunchAgents")
    (label ^ ".plist")

let xml_escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* The launchd agent: the pinned copy's `signer run`, started at login and kept alive, with the
   PATH it was installed under, so it finds gh and git as the signer's shell does. A job that
   ends (a refused token) is started again no sooner than ThrottleInterval. *)
let plist ~pinned ~path ~log =
  let s = xml_escape in
  String.concat "\n"
    [
      {|<?xml version="1.0" encoding="UTF-8"?>|};
      {|<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">|};
      {|<plist version="1.0">|};
      "<dict>";
      "  <key>Label</key>";
      Printf.sprintf "  <string>%s</string>" label;
      "  <key>ProgramArguments</key>";
      "  <array>";
      Printf.sprintf "    <string>%s</string>" (s pinned);
      "    <string>signer</string>";
      "    <string>run</string>";
      "  </array>";
      "  <key>EnvironmentVariables</key>";
      "  <dict>";
      "    <key>PATH</key>";
      Printf.sprintf "    <string>%s</string>" (s path);
      "  </dict>";
      "  <key>RunAtLoad</key>";
      "  <true/>";
      "  <key>KeepAlive</key>";
      "  <true/>";
      "  <key>ThrottleInterval</key>";
      "  <integer>300</integer>";
      "  <key>ProcessType</key>";
      "  <string>Background</string>";
      "  <key>StandardOutPath</key>";
      Printf.sprintf "  <string>%s</string>" (s log);
      "  <key>StandardErrorPath</key>";
      Printf.sprintf "  <string>%s</string>" (s log);
      "</dict>";
      "</plist>";
      "";
    ]

(* A signer token is the value POST /digestif/signer/tokens minted: refused when it holds anything
   but letters, digits, _ and -, so nothing else reaches the request's config line. *)
let check_token t =
  let t = String.trim t in
  if t = "" then Error "the signer token is empty"
  else if
    String.for_all
      (function
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
      t
  then Ok t
  else Error "a signer token holds only letters, digits, _ and -"

(* The release key, checked: an ed25519 secret whose public half is one of [signers]. *)
let check_key ~signers printed =
  let* secret =
    Result.map_error
      (fun e -> "the release key: " ^ e)
      (Keys.decode_secret printed)
  in
  let pub = Keys.public secret in
  if List.exists (fun (s : Release.signer) -> s.key = pub) signers then
    Ok (Keys.encode_secret secret, pub)
  else Error (Printf.sprintf "the key %s is not a release signer" pub)

(* What `signer install` hands the pinned copy on stdin: each value given at install, or empty
   for one the pinned copy reads from the item already in the Keychain. *)
type handover = { key : string; token : string }

let handover_to_string h =
  Yojson.Safe.to_string
    (`Assoc [ ("key", `String h.key); ("token", `String h.token) ])

let handover_of_string bytes =
  let* json = Release.parse_json "the handover" bytes in
  Ok
    {
      key = Option.value (str "key" json) ~default:"";
      token = Option.value (str "token" json) ~default:"";
    }

(* What to do about [service]'s value, [what], that could not be stored, by whether the Keychain
   still holds an item for it: `signer install` asks for a release key only when it holds none, so an
   item in the way is removed first. *)
let not_stored ~holds ~service ~what e =
  (* macOS ends its own messages with a period. *)
  let e =
    if String.ends_with ~suffix:"." e then String.sub e 0 (String.length e - 1)
    else e
  in
  if holds service then
    Printf.sprintf
      "%s. With your %s at hand in your password manager, remove the item, \
       then run signer install again and paste it when it asks:\n\
      \    %s"
      e what
      (Keychain.remove_command service)
  else
    Printf.sprintf
      "%s. The Keychain no longer holds your %s: run signer install again and \
       paste it from your password manager when it asks"
      e what

(* What the pinned copy does with the handover: each value handed over, or the one already in the
   Keychain, written back as an item this binary created, so its access list trusts this binary
   alone, then read back silently. Answers the key's public half. *)
let adopt ?(store = Keychain.store) ~signers ~account h =
  let read service =
    Result.map_error
      (Keychain.read_error_to_string service)
      (Keychain.read service)
  in
  let given v service = if v <> "" then Ok v else read service in
  let put ~service ~label ~what data =
    Result.map_error
      (not_stored ~holds:Keychain.holds ~service ~what)
      (store ~service ~account ~label data)
  in
  let* printed = given h.key Keychain.release_key_service in
  let* key, pub = check_key ~signers printed in
  let* token =
    Result.bind (given h.token Keychain.signer_token_service) check_token
  in
  let* () =
    put ~service:Keychain.release_key_service ~label:"Digestif release key"
      ~what:"release key" key
  in
  let* () =
    put ~service:Keychain.signer_token_service ~label:"Digestif signer token"
      ~what:"signer token" token
  in
  let* back = read Keychain.release_key_service in
  let* back_token = read Keychain.signer_token_service in
  if back = key && back_token = token then Ok pub
  else Error "the Keychain answered other values than were stored"

(* Every launchd agent of the signer's own, other than this one, whose plist runs `sign --next`:
   the sign-on-assignment job the signing job replaces. *)
let sign_on_assignment_jobs ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | names ->
      Array.to_list names
      |> List.filter (fun n ->
          Filename.check_suffix n ".plist" && n <> label ^ ".plist")
      |> List.filter_map (fun n ->
          let path = Filename.concat dir n in
          match In_channel.with_open_bin path In_channel.input_all with
          | exception Sys_error _ -> None
          | text ->
              if
                Layout.contains ~sub:"digestif-update" text
                && Layout.contains ~sub:"--next" text
              then Some (Filename.chop_suffix n ".plist")
              else None)
      |> List.sort compare
