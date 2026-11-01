(* The digestif binary: keys, the log, sync and the service. It holds no intelligence; behaviors
   are spawned programs that read and write through these commands. *)

open Digestif_core
open Digestif_daily
open Cmdliner

let die fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("digestif: " ^ s);
      exit 1)
    fmt

let ok_or_die = function Ok v -> v | Error e -> die "%s" e
let print_json j = print_endline (Yojson.Safe.pretty_to_string j)

let data_dir =
  let doc =
    "The node's data directory. Defaults to \\$DIGESTIF_HOME, else the \
     platform's application data directory."
  in
  Arg.(value & opt (some string) None & info [ "data-dir" ] ~docv:"DIR" ~doc)

let with_node dir f =
  let node = Node.open_ (Option.value dir ~default:(Node.default_dir ())) in
  Fun.protect ~finally:(fun () -> Node.close node) (fun () -> f node)

(* The phrase comes from stdin, so it never sits in an argv or a shell history. *)
let read_phrase () =
  if Unix.isatty Unix.stdin then prerr_string "Recovery phrase: ";
  In_channel.input_all stdin

let read_json_file path =
  try
    if path = "-" then Yojson.Safe.from_channel stdin
    else Yojson.Safe.from_file path
  with Yojson.Json_error m | Sys_error m -> die "%s: %s" path m

let cmd name doc term = Cmd.v (Cmd.info name ~doc) term

(* phrase *)

let phrase_new =
  cmd "new"
    "Print a new 24-word recovery phrase. Nothing is stored; write it down."
    Term.(const (fun () -> print_endline (Phrase.generate ())) $ const ())

let phrase_check =
  cmd "check"
    "Check a recovery phrase read from stdin and print the public keys it \
     derives."
    Term.(
      const (fun () ->
          let d = ok_or_die (Phrase.derive (read_phrase ())) in
          print_json
            (`Assoc
               [
                 ("identity_key", `String (Keys.public d.identity));
                 ( "encryption_key",
                   `String (Keys.encryption_public d.encryption) );
               ]))
      $ const ())

(* init and keys *)

let init =
  let root =
    Arg.(
      value
      & opt (some string) None
      & info [ "root" ] ~docv:"HASH"
          ~doc:"The circle root: the founding dinner's envelope hash.")
  in
  let relays =
    Arg.(
      value & opt_all string []
      & info [ "relay" ] ~docv:"URL"
          ~doc:"A relay to read and write. Repeatable.")
  in
  cmd "init"
    "Set up this machine: read the recovery phrase from stdin, create the \
     device and mail keys in the system keystore, cache the encryption key, \
     sign the mail key's device body (appended once this machine is admitted), \
     and record the circle root and relays."
    Term.(
      const (fun dir root relays ->
          with_node dir (fun node ->
              let d = ok_or_die (Node.init node ~phrase:(read_phrase ())) in
              ok_or_die (Mail_key.prepare node ~identity:d.identity);
              Option.iter (Node.set_root node) root;
              List.iter (Log.add_relay node.log) relays;
              Printf.printf
                "identity   %s\n\
                 encryption %s\n\
                 device     %s\n\
                 mail       %s\n\
                 keystore   %s\n"
                (Keys.public d.identity)
                (Keys.encryption_public d.encryption)
                (Option.value
                   (Log.get_config node.log Node.k_device)
                   ~default:"")
                (Option.value (Log.get_config node.log Node.k_mail) ~default:"")
                node.keystore.backend))
      $ data_dir $ root $ relays)

let keys =
  cmd "keys" "Print this node's public keys and circle root."
    Term.(
      const (fun dir ->
          with_node dir (fun node ->
              let c k =
                match Log.get_config node.log k with
                | Some v -> `String v
                | None -> `Null
              in
              print_json
                (`Assoc
                   [
                     ("identity_key", c Node.k_identity);
                     ("device_key", c Node.k_device);
                     ("mail_key", c Node.k_mail);
                     ("encryption_key", c Node.k_encryption);
                     ("root", c Node.k_root);
                     ("keystore", `String node.keystore.backend);
                   ])))
      $ data_dir)

(* relays *)

let relay_add =
  let url = Arg.(required & pos 0 (some string) None & info [] ~docv:"URL") in
  let mine =
    Arg.(
      value & flag
      & info [ "mine" ]
          ~doc:
            "You run this relay: publish a relay message naming it, so every \
             node in the circle adds it at its next sync.")
  in
  cmd "add" "Add a relay."
    Term.(
      const (fun dir url mine ->
          with_node dir (fun n ->
              if not mine then Log.add_relay n.log url
              else
                match ok_or_die (Node.add_own_relay n url) with
                | Some hash -> Printf.printf "published\t%s\n" hash
                | None -> Printf.printf "already in the circle\t%s\n" url))
      $ data_dir $ url $ mine)

let relay_remove =
  let url = Arg.(required & pos 0 (some string) None & info [] ~docv:"URL") in
  cmd "remove" "Stop using a relay."
    Term.(
      const (fun dir url -> with_node dir (fun n -> Log.remove_relay n.log url))
      $ data_dir $ url)

let relay_list =
  cmd "list" "List relays with their cursor and last sync."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (r : Log.relay_row) ->
                  Printf.printf "%s\tcursor %d\tlast sync %s%s\n" r.url r.cursor
                    (Option.value r.last_sync_at ~default:"never")
                    (match r.last_error with
                    | Some e -> "\terror " ^ e
                    | None -> ""))
                (Log.relays n.log)))
      $ data_dir)

(* the log *)

let report_sync (r : Sync.report) =
  List.iter
    (fun (rr : Sync.relay_report) ->
      Printf.printf "%s\tfetched %d\tnew %d\tpushed %d%s\n" rr.relay rr.fetched
        rr.stored rr.pushed
        (match rr.error with Some e -> "\terror " ^ e | None -> ""))
    r.relays;
  List.iter
    (fun (f : Log.fault) ->
      Printf.printf "fault %s\t%s seq %d\t%s\n" f.kind f.author f.seq f.detail)
    r.faults

(* What the join watcher made of the joins a sync stored. *)
let report_joins seen =
  List.iter
    (fun (s : Digestif_invite.Invite_node.seen) ->
      match s.outcome with
      | Digestif_invite.Host_watch.Shown r ->
          Printf.printf "joined\t%s\t%s, as you expected\n" s.join_hash
            r.guest_name
      | Asked (r, a) ->
          Printf.printf "ask\t%s\t%s: %s (digestif asks)\n" a.key r.guest_name
            a.title
      | Already_handled _ | Not_ours -> ())
    seen

(* A sync that runs the join watcher over the joins it stores, reporting what it made of them. *)
let watch_joins n =
  match Digestif_invite.Invite_node.sync n with
  | Ok (r, seen) ->
      report_joins seen;
      Ok r
  | Error e -> Error e

(* What the circle's release-key revocations did to this node's update state (Circle_revocation). *)
let report_release_revocations = function
  | Ok keys ->
      List.iter
        (fun k ->
          Printf.printf "update\t%s\n"
            (Digestif_update.Circle_revocation.outcome_to_string
               (Digestif_update.Circle_revocation.Revoked k)))
        keys
  | Error e ->
      Printf.printf
        "update\tthe circle's release revocations were not applied: %s\n" e

let sync_node n =
  match watch_joins n with
  | Ok r ->
      report_sync r;
      report_release_revocations
        (Digestif_update.Circle_revocation.from_circle
           ~state_path:(Digestif_update.Schedule.state_path n.Node.dir)
           n r.fold);
      Ok r
  | Error e -> Error e

let sync_cmd =
  cmd "sync"
    "Read every relay, verify and store what is new, fold, and push our \
     envelopes each relay lacks. A join on one of this host's invites is \
     shown, or raised as an ask."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              let r = ok_or_die (sync_node n) in
              if
                List.exists
                  (fun (rr : Sync.relay_report) -> rr.error <> None)
                  r.relays
              then exit 2))
      $ data_dir)

let kind_arg =
  Arg.(value & opt (some string) None & info [ "kind" ] ~docv:"KIND")

let log_cmd =
  cmd "log" "Print the log, one envelope per line, oldest first."
    Term.(
      const (fun dir kind ->
          with_node dir (fun n ->
              let rows =
                match kind with
                | Some k -> Log.of_kind n.log k
                | None -> Log.all n.log
              in
              List.iter
                (fun (r : Log.row) ->
                  let e = r.signed.envelope in
                  Printf.printf "%s\t%s\t%s\tseq %d\tepoch %d\t%s%s\n" r.hash
                    e.created_at e.kind e.seq e.epoch e.author
                    (if r.retracted_by <> None then "\tretracted" else ""))
                rows))
      $ data_dir $ kind_arg)

let show =
  let hash = Arg.(required & pos 0 (some string) None & info [] ~docv:"HASH") in
  cmd "show" "Print one envelope with its body and where each relay holds it."
    Term.(
      const (fun dir hash ->
          with_node dir (fun n ->
              match Log.find n.log hash with
              | None -> die "no envelope %s" hash
              | Some r ->
                  print_json
                    (`Assoc
                       [
                         ("hash", `String r.hash);
                         ("signed", Envelope.signed_to_json r.signed);
                         ( "sightings",
                           `List
                             (List.map
                                (fun (relay, id, _) ->
                                  `Assoc
                                    [
                                      ("relay", `String relay);
                                      ("relay_id", `Int id);
                                    ])
                                (Log.sightings n.log hash)) );
                       ])))
      $ data_dir $ hash)

let faults =
  cmd "faults"
    "Print open faults: forks, gaps, broken chains, envelopes a relay served \
     that do not verify."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (f : Log.fault) ->
                  Printf.printf "%s\t%s\t%s seq %d\t%s\n" f.detected_at f.kind
                    f.author f.seq f.detail)
                (Log.open_faults n.log)))
      $ data_dir)

let circle =
  cmd "circle"
    "Print the circle as this node folds it: epoch, admitted keys, cards, \
     relays, and what was refused."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              let f = Node.fold n in
              let keys =
                Hashtbl.fold
                  (fun _ (k : Fold.key_state) acc ->
                    `Assoc
                      ([
                         ("key", `String k.key);
                         ("role", `String (Bodies.role_to_string k.role));
                         ("identity", `String k.identity);
                         ("join_epoch", `Int k.join_epoch);
                       ]
                      @ (match k.revoked_by with
                        | Some r -> [ ("revoked_by", `String r) ]
                        | None -> [])
                      @ (match k.after_seq with
                        | Some n -> [ ("after_seq", `Int n) ]
                        | None -> [])
                      @
                      match k.mail_read with
                      | Some hs ->
                          [
                            ( "mail_read",
                              `List
                                (List.map
                                   (fun h -> `String h)
                                   (Fold.Hashes.elements hs)) );
                          ]
                      | None -> [])
                    :: acc)
                  f.keys []
              in
              let cards =
                Hashtbl.fold
                  (fun id ((c : Bodies.card), _) acc ->
                    `Assoc
                      [
                        ("identity", `String id);
                        ("name", `String c.card_name);
                        ("agent_name", `String c.agent_name);
                        ("encryption_key", `String c.encryption_key);
                      ]
                    :: acc)
                  f.cards []
              in
              let pairs l =
                `List
                  (List.map
                     (fun (h, m) ->
                       `Assoc [ ("hash", `String h); ("reason", `String m) ])
                     l)
              in
              print_json
                (`Assoc
                   [
                     ("root", `String f.root);
                     ("epoch", `Int f.epoch);
                     ("keys", `List keys);
                     ("cards", `List cards);
                     ( "relays",
                       `List
                         (Hashtbl.fold
                            (fun u _ acc -> `String u :: acc)
                            f.relays []) );
                     ("rejected", pairs f.rejected);
                     ("waiting", pairs f.waiting);
                   ])))
      $ data_dir)

(* writing *)

let post =
  let kind =
    Arg.(required & opt (some string) None & info [ "kind" ] ~docv:"KIND")
  in
  let body =
    Arg.(
      required
      & opt (some string) None
      & info [ "body" ] ~docv:"FILE" ~doc:"The body as JSON, or - for stdin.")
  in
  let key =
    Arg.(
      value & opt string "device"
      & info [ "key" ] ~docv:"NAME" ~doc:"Which key signs: device or mail.")
  in
  cmd "post"
    "Sign a body as the next envelope of this device's chain and write it to \
     the log; the next sync pushes it. A summary, question, answer or proposal \
     passes the deny layer first: a trip signs nothing, keeps the refusal for \
     the web UI, prints the rule and exits 3."
    Term.(
      const (fun dir kind body key ->
          with_node dir (fun n ->
              Digestif_web.Store.init n.log;
              match
                Digestif_web.Api.post_body n ~key_name:key ~kind
                  (read_json_file body)
              with
              | Ok hash -> print_endline hash
              | Error (Failed e) -> die "%s" e
              | Error (Refused rule) ->
                  prerr_endline ("digestif: refused by the deny layer: " ^ rule);
                  exit 3))
      $ data_dir $ kind $ body $ key)

let import =
  let file =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"FILE" ~doc:"A signed_envelope as JSON, or -.")
  in
  cmd "import"
    "Verify a signed envelope written elsewhere (a founding dinner) and store \
     it."
    Term.(
      const (fun dir file ->
          with_node dir (fun n ->
              let sg =
                match Envelope.signed_of_json (read_json_file file) with
                | Ok s -> s
                | Error e -> die "%s" (Envelope.error_message e)
              in
              print_endline (ok_or_die (Node.import n sg))))
      $ data_dir $ file)

let verify =
  let file =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"FILE" ~doc:"A signed_envelope as JSON, or -.")
  in
  cmd "verify" "Verify a signed envelope and print its hash."
    Term.(
      const (fun file ->
          match Envelope.signed_of_json (read_json_file file) with
          | Error e -> die "%s" (Envelope.error_message e)
          | Ok sg -> (
              match Envelope.verify sg with
              | Ok () -> print_endline (Envelope.hash sg.envelope)
              | Error e -> die "%s" (Envelope.error_message e)))
      $ file)

let card =
  let name =
    Arg.(required & opt (some string) None & info [ "name" ] ~docv:"NAME")
  in
  let agent =
    Arg.(required & opt (some string) None & info [ "agent-name" ] ~docv:"NAME")
  in
  cmd "card" "Publish this member's card: name, agent name and encryption key."
    Term.(
      const (fun dir name agent_name ->
          with_node dir (fun n ->
              let enc = ok_or_die (Node.encryption_key n) in
              let body =
                Bodies.make_card ~name ~agent_name
                  ~encryption_key:(Keys.encryption_public enc)
              in
              print_endline (fst (ok_or_die (Node.write n ~kind:"card" body)))))
      $ data_dir $ name $ agent)

let device_publish =
  let role =
    Arg.(
      value
      & opt
          (enum [ ("mail", Bodies.Mail); ("device", Bodies.Device) ])
          Bodies.Mail
      & info [ "role" ])
  in
  cmd "publish"
    "Admit this machine's mail key (or, after a lost laptop, its device key): \
     reads the recovery phrase from stdin to sign it."
    Term.(
      const (fun dir role ->
          with_node dir (fun n ->
              let identity =
                ok_or_die (Node.identity_from_phrase n (read_phrase ()))
              in
              let key =
                match role with
                | Bodies.Mail -> Keys.public (ok_or_die (Node.mail_key n))
                | _ -> Keys.public (ok_or_die (Node.device_key n))
              in
              let body = Bodies.make_device ~identity ~key ~role in
              print_endline (fst (ok_or_die (Node.write n ~kind:"device" body)))))
      $ data_dir $ role)

let revoke =
  let target =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"KEY")
  in
  cmd "revoke"
    "Revoke a device key, or an identity, signed by the identity re-derived \
     from the phrase on stdin. Fetches every relay first: the revoke keeps \
     what this node holds of the stopped keys and nothing else."
    Term.(
      const (fun dir target ->
          with_node dir (fun n ->
              let by =
                ok_or_die (Node.identity_from_phrase n (read_phrase ()))
              in
              (match Sync.sync n with
              | Ok r ->
                  List.iter
                    (fun (rep : Sync.relay_report) ->
                      match rep.error with
                      | Some e ->
                          prerr_endline
                            ("warning: " ^ rep.relay ^ " was not read: " ^ e)
                      | None -> ())
                    r.relays
              | Error e -> prerr_endline ("warning: sync failed: " ^ e));
              print_endline
                (fst
                   (ok_or_die
                      (Node.write n ~kind:"revoke"
                         (ok_or_die (Node.revoke_body n ~by ~target)))))))
      $ data_dir $ target)

let retract =
  let target =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"HASH")
  in
  cmd "retract"
    "Retract one of this member's envelopes: relays and nodes drop its body \
     and keep the envelope."
    Term.(
      const (fun dir target ->
          with_node dir (fun n ->
              print_endline
                (fst
                   (ok_or_die
                      (Node.write n ~kind:"retract"
                         (Bodies.make_retract ~target))))))
      $ data_dir $ target)

(* the web UI *)

let ui_port =
  Arg.(
    value & opt int 7420
    & info [ "ui-port" ] ~docv:"PORT"
        ~doc:
          "The port the web UI listens on, on 127.0.0.1 only. 0 takes any free \
           port.")

let open_browser url =
  let opener = if Keystore.is_macos () then "open" else "xdg-open" in
  match Proc.run [| opener; url |] with
  | Ok { code = 0; _ } -> ()
  | _ -> prerr_endline ("digestif: open this link in a browser: " ^ url)

let print_launch node ~browse =
  let url = ok_or_die (Digestif_web.Server.launch_url node) in
  print_endline url;
  flush stdout;
  if browse then open_browser url

let stop_on_signals () =
  let stop = ref false in
  List.iter
    (fun s -> Sys.set_signal s (Sys.Signal_handle (fun _ -> stop := true)))
    [ Sys.sigterm; Sys.sigint ];
  stop

let ui_cmd =
  let browse =
    Arg.(
      value & flag & info [ "open" ] ~doc:"Open the launch link in the browser.")
  in
  cmd "ui"
    "Serve the web UI and the local API on 127.0.0.1 without syncing, and \
     print a one-time launch link. digestif run serves it too."
    Term.(
      const (fun dir port browse ->
          let stop = stop_on_signals () in
          with_node dir (fun n ->
              let fd = ok_or_die (Digestif_web.Server.start ~port n) in
              print_launch n ~browse;
              Digestif_web.Server.serve ~stop:(fun () -> !stop) n fd))
      $ data_dir $ ui_port $ browse)

let open_cmd =
  let print_only =
    Arg.(
      value & flag & info [ "print" ] ~doc:"Print the link and open nothing.")
  in
  cmd "open"
    "Open the running node's web UI: mint a one-time launch link, good for \
     five minutes, and open it in the browser."
    Term.(
      const (fun dir print_only ->
          with_node dir (fun n ->
              Digestif_web.Store.init n.log;
              print_launch n ~browse:(not print_only)))
      $ data_dir $ print_only)

let note_cmd =
  let text =
    Arg.(
      required
      & opt (some string) None
      & info [ "text" ] ~docv:"FILE" ~doc:"The note's text, or - for stdin.")
  in
  let hold =
    Arg.(
      value
      & opt (some string) None
      & info [ "hold" ] ~docv:"REASON"
          ~doc:
            "The business-information screen flagged the note, for this \
             reason. The note waits in the web UI for the member whatever \
             their approval settings.")
  in
  cmd "note"
    "Hand the node tonight's note from the writer. The deny layer checks it; \
     while any of the member's first five notes is unapproved, or when \
     $(b,--hold) says the screen flagged it, it waits in the web UI, and \
     otherwise it is signed and posted on the next sync."
    Term.(
      const (fun dir text hold ->
          let text =
            if text = "-" then In_channel.input_all stdin
            else In_channel.with_open_bin text In_channel.input_all
          in
          with_node dir (fun n ->
              Digestif_web.Store.init n.log;
              print_endline
                (ok_or_die
                   (Digestif_web.Api.submit_note_text ?hold n (String.trim text)))))
      $ data_dir $ text $ hold)

let tick_cmd =
  let outcome =
    let open Digestif_web.Store in
    Arg.(
      required
      & opt
          (some
             (enum
                [
                  ("quiet", Quiet);
                  ("harness_signed_out", Harness_signed_out);
                  ("failed", Failed);
                ]))
          None
      & info [ "outcome" ] ~docv:"OUTCOME"
          ~doc:
            "$(b,quiet) when the run had nothing to say, \
             $(b,harness_signed_out) when it could not use the member's agent \
             harness, $(b,failed) when every try of the local date failed \
             (with $(b,--note) saying why; the Approvals page shows it).")
  in
  let note =
    Arg.(
      value
      & opt (some string) None
      & info [ "note" ] ~docv:"TEXT"
          ~doc:
            "Why, in the run's own words, it handed over no note. It passes \
             the deny layer and goes into the next digest's silence report.")
  in
  cmd "tick"
    "Record a run of the nightly pipeline that hands the node no note, so the \
     Members page and the digest can say why this node is silent. A run that \
     hands over a note records itself through $(b,digestif note)."
    Term.(
      const (fun dir outcome note ->
          with_node dir (fun n ->
              Digestif_web.Store.init n.log;
              match note with
              | Some text ->
                  ignore
                    (ok_or_die
                       (Digestif_web.Api.silence_note_text ~outcome n text))
              | None -> Digestif_web.Store.add_tick n.log outcome))
      $ data_dir $ outcome $ note)

let demo_cmd =
  let home =
    Arg.(
      required
      & opt (some string) None
      & info [ "home" ] ~docv:"DIR"
          ~doc:
            "A throwaway directory for the demo node. Keys are kept in plain \
             files there.")
  in
  let port =
    Arg.(
      value & opt int 0
      & info [ "port" ] ~docv:"PORT" ~doc:"0 takes any free port.")
  in
  cmd "demo"
    "Serve the web UI against a made-up circle in a throwaway node (the circle \
     ui/mock/fixtures.ts describes, with real keys and signed envelopes), for \
     developing the UI and running its Playwright suite against the node. POST \
     /api/v0/_reset reseeds it. Prints the one-time launch link."
    Term.(
      const (fun home port ->
          let log_path = Filename.concat home "log.sqlite3" in
          if
            Sys.file_exists log_path
            && not (Sys.file_exists (Filename.concat home "demo"))
          then
            die "%s holds a node that is not a demo; name an empty directory"
              home;
          let stop = stop_on_signals () in
          let keystore = Keystore.insecure_dir (Filename.concat home "keys") in
          let n = Node.open_ ~keystore home in
          Fun.protect
            ~finally:(fun () -> Node.close n)
            (fun () ->
              let fd = ok_or_die (Digestif_web.Server.start ~port n) in
              ok_or_die (Digestif_web.Demo.seed n);
              print_launch n ~browse:false;
              Digestif_web.Server.serve
                ~reset:(fun () -> ok_or_die (Digestif_web.Demo.seed n))
                ~stop:(fun () -> !stop)
                n fd))
      $ home $ port)

(* self-update *)

module U = Digestif_update

let node_dir dir = Option.value dir ~default:(Node.default_dir ())

let exe () =
  let e = Sys.executable_name in
  if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e

(* The file an install replaces: the binary itself, not a symlink pointing at it. *)
let binary () = try Unix.realpath (exe ()) with Unix.Unix_error _ -> exe ()

let feed =
  Arg.(
    value
    & opt string U.Feed.default_url
    & info [ "feed" ] ~docv:"URL"
        ~doc:
          "Release channel: an https URL or a local directory holding \
           index.json.")

let platform () =
  match U.Platform.current () with Ok p -> p | Error e -> die "%s" e

let print_plan (plan : U.Policy.plan) problems =
  List.iter (fun p -> Printf.printf "unreadable: %s\n" p) problems;
  List.iter
    (fun (s : U.Policy.skipped) ->
      Printf.printf "refused %s: %s\n"
        (U.Version.to_string s.skipped_version)
        s.reason)
    plan.skipped;
  Option.iter
    (fun v -> Printf.printf "pinned at %s\n" (U.Version.to_string v))
    plan.pinned_at;
  Printf.printf "signers: %s\n"
    (match plan.trust.signers with
    | [] -> "none configured"
    | l ->
        String.concat ", "
          (List.map (fun (s : U.Release.signer) -> s.name ^ " " ^ s.key) l));
  List.iter (fun k -> Printf.printf "revoked: %s\n" k) plan.trust.revoked

let print_layout dir =
  let name l = Option.value l ~default:"-" in
  Printf.printf "current %s\n" (name (U.Layout.current dir));
  Printf.printf "good %s\n" (name (U.Layout.good dir));
  Option.iter
    (fun (t : U.Trial.t) ->
      Printf.printf "on trial %s (start %d of %d)\n"
        (U.Version.to_string t.version)
        t.starts U.Supervisor.max_starts)
    (U.Trial.load dir)

let print_state (state : U.State.t) =
  Printf.printf "installed %s\n" (U.Version.to_string state.installed);
  Option.iter
    (fun (p : U.State.pending) ->
      Printf.printf "staging %s failed %d times: %s; next try after %s\n"
        (U.Version.to_string p.pending_version)
        p.attempts p.cause
        (U.Schedule.clock_line p.due_at))
    state.pending;
  List.iter
    (fun (r : U.State.refused) ->
      Printf.printf "refused for good %s: %s\n"
        (U.Version.to_string r.refused_version)
        r.why)
    state.refused

let update_check =
  cmd "check"
    "Say what an update would install, and what the next digest will report \
     about updates, changing nothing."
    Term.(
      const (fun dir base ->
          let dir = node_dir dir in
          let state = ok_or_die (U.State.load (U.Schedule.state_path dir)) in
          let plan, recalls, problems =
            ok_or_die
              (U.Updater.check ~fetch:U.Feed.default_fetch ~base
                 ~platform:(platform ()) state)
          in
          print_state state;
          print_layout dir;
          print_plan plan problems;
          (match
             U.Policy.recall_of plan.trust recalls (U.Recall.running ~dir state)
           with
          | Some r ->
              Printf.printf "running a recalled version: %s\n"
                (U.Policy.recalled_line r)
          | None -> ());
          (match plan.install with
          | Some r ->
              Printf.printf "would install %s\n"
                (U.Version.to_string r.doc.version)
          | None -> print_endline "nothing to install");
          let report = U.Report.load (U.Schedule.report_path dir) in
          List.iter
            (fun l -> Printf.printf "next digest: %s\n" l)
            report.pending)
      $ data_dir $ feed)

let update_apply =
  cmd "apply"
    "Stage the newest release both signers signed, or the pinned one, now, and \
     switch to it. The running service exits after a switch and its supervisor \
     runs the new release on trial; `digestif run` does this daily on its own."
    Term.(
      const (fun dir base ->
          let dir = node_dir dir in
          let cfg = U.Schedule.config ~base ~dir () in
          let result, lines = U.Schedule.pass cfg ~now:(Unix.gettimeofday ()) in
          List.iter print_endline lines;
          match result with
          | U.Schedule.Switched v ->
              Printf.printf
                "switched to %s; restart the service to run it on trial\n"
                (U.Version.to_string v)
          | Moved_back (from, to_) ->
              Printf.printf
                "moved back from recalled %s to %s; restart the service to run \
                 it\n"
                (U.Version.to_string from) (U.Version.to_string to_)
          | Not_switched -> print_endline "nothing switched")
      $ data_dir $ feed)

(* What the supervisor's binary checks a release with before the switch: it reports its version,
   opens the store and reads its config, against a copy of the node's data (Stage.self_test). *)
let self_test =
  let expect =
    Arg.(
      value
      & opt (some string) None
      & info [ "expect-version" ] ~docv:"VERSION"
          ~doc:"Fail unless this binary is VERSION.")
  in
  cmd "self-test"
    "Check this binary against a node's data directory: its version, the store \
     opens, its config reads. A release is tested this way before a node \
     switches to it."
    Term.(
      const (fun dir expect ->
          let mine = U.Version.to_string (U.Trust_root.version ()) in
          Printf.printf "version %s\n" mine;
          (match expect with
          | Some v when v <> mine -> die "this binary is %s, not %s" mine v
          | _ -> ());
          with_node dir (fun n ->
              Printf.printf "store %d envelopes\n" (Log.count n.log);
              Printf.printf "relays %d\n" (List.length (Log.relays n.log));
              Printf.printf "root %s\n"
                (Option.value (Node.root n) ~default:"-")))
      $ data_dir $ expect)

(* The service's process (Supervisor): the last healthy release's binary, running the current one. *)
let supervise =
  cmd "supervise"
    "Run `current/bin/digestif run` and keep a switch only once the new \
     release reports healthy; otherwise move back to the last healthy release. \
     This is what the service runs (docs/releases.md)."
    Term.(
      const (fun dir ->
          let dir = node_dir dir in
          let on_signal _ = U.Supervisor.stop_requested := true in
          Sys.set_signal Sys.sigterm (Sys.Signal_handle on_signal);
          Sys.set_signal Sys.sigint (Sys.Signal_handle on_signal);
          let on_trial = function
            | U.Supervisor.Healthy v ->
                Printf.printf "%s supervise: %s is healthy\n%!"
                  (Time_fmt.now ()) (U.Version.to_string v)
            | Rolled_back (v, why) ->
                Printf.printf "%s supervise: rolled back %s: %s\n%!"
                  (Time_fmt.now ()) (U.Version.to_string v) why
            | Interrupted v ->
                Printf.printf "%s supervise: stopped during the trial of %s\n%!"
                  (Time_fmt.now ()) (U.Version.to_string v)
          in
          match U.Supervisor.run ~on_trial (U.Supervisor.real_ops ~dir) dir with
          | U.Supervisor.Exited n -> exit n
          | Signaled _ -> exit 1)
      $ data_dir)

let update_state dir f =
  let path = U.Schedule.state_path (node_dir dir) in
  let s = ok_or_die (U.State.load path) in
  U.State.save path (ok_or_die (f s))

let update_pin =
  let v = Arg.(required & pos 0 (some string) None & info [] ~docv:"VERSION") in
  cmd "pin" "Install only VERSION from now on; nothing newer."
    Term.(
      const (fun dir v ->
          update_state dir (fun s ->
              Result.map
                (fun v -> { s with U.State.pin = Some v })
                (U.Version.of_string v)))
      $ data_dir $ v)

let update_unpin =
  cmd "unpin" "Follow the newest release again."
    Term.(
      const (fun dir ->
          update_state dir (fun s -> Ok { s with U.State.pin = None }))
      $ data_dir)

(* the daily acts *)

let source_label : Decisions.source -> string = function
  | Decided -> "decided"
  | Lapsed -> "lapsed"
  | Answered -> "answered"

let report_daily (p : Daily.report) =
  report_release_revocations p.release_revocations;
  (match p.mail_key with
  | Mail_key.Appended h -> Printf.printf "mail key\tadmitting %s\n" h
  | Needs_phrase ->
      print_endline
        "mail key\tnot admitted; run digestif device publish --role mail"
  | Admitted | Waiting -> ());
  List.iter
    (fun (a : Decisions.ask) ->
      match a.outcome with
      | Some o ->
          Printf.printf "ask %s\t%s\t%s%s\n" a.key o.option
            (source_label o.source)
            (match a.revoke with
            | Some h -> "\trevoke " ^ h ^ "; the next sync pushes it"
            | None -> "")
      | None -> ())
    p.settled;
  List.iter
    (fun (a : Asks.t) ->
      Printf.printf
        "ask %s\tlapsed; revoking takes the phrase: digestif asks answer %s \
         revoke\n"
        a.key a.key)
    p.needs_phrase;
  (match p.digest with
  | Ok (Some w) ->
      Printf.printf "digest %s\t%d asks\tmail via %s\n" w.digest
        (List.length w.asks) w.relay
  | Ok None -> ()
  | Error e -> Printf.printf "digest\tnot written: %s\n" e);
  List.iter
    (fun (s : Daily_digest.sent) ->
      Printf.printf "mail %s\t%s\n" s.digest
        (match s.result with
        | Ok Sent -> "sent"
        | Ok Already_sent -> "already sent"
        | Error e -> "kept: " ^ e))
    p.sent

let ask_add =
  let file =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"FILE"
          ~doc:
            "The ask's plaintext as JSON (title, detail, about, options, \
             on_no_answer, lapses_at), or -.")
  in
  let key =
    Arg.(
      value
      & opt (some string) None
      & info [ "key" ] ~docv:"KEY"
          ~doc:
            "What the ask is about. Adding another ask under the same key \
             replaces the open one.")
  in
  cmd "add"
    "Raise an ask in this node's ask store. The next digest appends it, sealed \
     to this member."
    Term.(
      const (fun dir file key ->
          let ask =
            ok_or_die (Digestif_mail.Ask.of_plaintext (read_json_file file))
          in
          with_node dir (fun n ->
              print_endline (ok_or_die (Asks_mail.add ?key n.log ask))))
      $ data_dir $ file $ key)

let ask_list =
  cmd "list"
    "List this member's asks: waiting for a digest, open, or settled with the \
     option acted on."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (a : Decisions.ask) ->
                  Printf.printf "%s\t%s\t%s%s\n" a.key
                    (match (a.outcome, a.hash) with
                    | Some o, _ -> source_label o.source ^ " " ^ o.option
                    | None, None -> "waiting for the next digest"
                    | None, Some _ -> "open until " ^ a.ask.lapses_at)
                    a.ask.title
                    (match List.length a.decisions with
                    | n when n > 1 -> Printf.sprintf "\t%d later answers" (n - 1)
                    | _ -> ""))
                (ok_or_die (Decisions.read n (Node.fold n)))))
      $ data_dir)

let digest_email =
  let address =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"ADDRESS")
  in
  cmd "email"
    "Where the daily digest is mailed. Until it is set, none is written."
    Term.(
      const (fun dir address ->
          with_node dir (fun n ->
              Log.set_config n.log Daily_digest.k_email address))
      $ data_dir $ address)

let digest_hour =
  let hour = Arg.(required & pos 0 (some int) None & info [] ~docv:"HOUR") in
  cmd "hour"
    "The local hour, 0 to 23, after which the day's digest is written. \
     Defaults to 7."
    Term.(
      const (fun dir hour ->
          if hour < 0 || hour > 23 then die "the hour is 0 to 23";
          with_node dir (fun n ->
              Log.set_config n.log Daily_digest.k_hour (string_of_int hour)))
      $ data_dir $ hour)

let phone_add =
  let code =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"CODE" ~doc:"The pairing code the phone shows (p1....).")
  in
  cmd "add"
    "Pair a phone: admit the key its pairing code carries, signed by the \
     identity re-derived from the phrase on stdin, with the enrollment that \
     hands the phone this member's encryption key. The next sync appends it."
    Term.(
      const (fun dir code ->
          with_node dir (fun n ->
              let hash, key =
                ok_or_die
                  (Result.map_error Phones.error_message
                     (Phones.add n ~phrase:(read_phrase ()) ~code))
              in
              Printf.printf "%s\t%s\n" hash key))
      $ data_dir $ code)

(* invites *)

module Inv = Digestif_invite

(* "Roman Cherkasov <roman@example.com>", optionally followed by mac or linux. *)
let parse_guest s =
  match (String.index_opt s '<', String.index_opt s '>') with
  | Some i, Some j when j > i + 1 -> (
      let name = String.trim (String.sub s 0 i) in
      let email = String.trim (String.sub s (i + 1) (j - i - 1)) in
      let rest =
        String.lowercase_ascii
          (String.trim (String.sub s (j + 1) (String.length s - j - 1)))
      in
      let platform =
        match rest with
        | "" -> Ok None
        | "mac" | "macos" -> Ok (Some Inv.Dinner.Mac)
        | "linux" -> Ok (Some Inv.Dinner.Linux)
        | p ->
            Error
              (Printf.sprintf "%S: the platform is mac or linux, not %S" s p)
      in
      match platform with
      | Error e -> Error e
      | Ok platform -> Ok { Inv.Dinner.name; email; platform })
  | _ ->
      Error
        (Printf.sprintf
           "%S: name a guest as \"Full Name <email>\", optionally followed by \
            mac or linux"
           s)

let guest_conv =
  Arg.conv
    ( (fun s -> Result.map_error (fun e -> `Msg e) (parse_guest s)),
      fun ppf (g : Inv.Dinner.guest) ->
        Format.fprintf ppf "%s <%s>" g.name g.email )

let print_email (e : Inv.Invite_email.t) =
  Printf.printf "To: %s\nSubject: %s\n\n%s\n\n%s\n\n" e.to_ e.subject e.text
    (Inv.Invite_email.mailto e)

(* The name the email is signed with: --from, else this member's own card. *)
let has_card n =
  match Log.get_config n.Node.log Node.k_identity with
  | Some id -> Hashtbl.mem (Node.fold n).cards id
  | None -> false

let host_name n from =
  match from with
  | Some f -> f
  | None -> (
      let f = Node.fold n in
      match Log.get_config n.Node.log Node.k_identity with
      | Some id -> (
          match Hashtbl.find_opt f.cards id with
          | Some ((c : Bodies.card), _) -> c.card_name
          | None ->
              die "this member has no card yet; sign the email with --from NAME"
          )
      | None -> die "this node has no identity; run digestif init")

let invite_create =
  let date =
    Arg.(
      required
      & opt (some string) None
      & info [ "date" ] ~docv:"YYYY-MM-DD" ~doc:"The night of the dinner.")
  in
  let label =
    Arg.(
      required
      & opt (some string) None
      & info [ "label" ] ~docv:"TEXT"
          ~doc:"What the dinner is called, as the email names it.")
  in
  let guests =
    Arg.(
      non_empty & opt_all guest_conv []
      & info [ "guest" ] ~docv:"\"NAME <EMAIL> [mac|linux]\""
          ~doc:"A guest to invite. Repeatable.")
  in
  let relays =
    Arg.(
      value & opt_all string []
      & info [ "relay" ] ~docv:"URL"
          ~doc:
            "A relay the dinner lists; repeatable. Defaults to this node's \
             relays. The first is the one each invite code names.")
  in
  let from =
    Arg.(
      value
      & opt (some string) None
      & info [ "from" ] ~docv:"NAME"
          ~doc:"The name the emails are signed with. Defaults to your card.")
  in
  let hours =
    Arg.(
      value & opt int 72
      & info [ "expires-in" ] ~docv:"HOURS"
          ~doc:"How long each invite code works.")
  in
  Term.(
    const (fun dir date label guests relays from hours ->
        with_node dir (fun n ->
            let carded = has_card n in
            let from = host_name n from in
            let inv =
              ok_or_die
                (Inv.Invite_node.invite n ~date ~label ~relays
                   ~ttl:(Ptime.Span.of_int_s (hours * 3600))
                   guests)
            in
            (* A host with no card is read as a key; the name the emails are signed with becomes it.
               After the dinner, which founds a new circle and so must come first. *)
            if not carded then
              ignore
                (ok_or_die
                   (Inv.Invite_node.write_card n ~name:from
                      ~agent_name:(Inv.Invite_node.default_agent_name from)));
            Printf.printf "dinner %s\n\n" inv.dinner_hash;
            List.iter
              (fun i ->
                print_email
                  (Inv.Invite_email.render ~host_name:from ~dinner:inv.dinner i))
              inv.dinner.invites;
            match sync_node n with
            | Ok r ->
                if
                  List.exists
                    (fun (rr : Sync.relay_report) -> rr.error <> None)
                    r.relays
                then
                  prerr_endline
                    "digestif: a relay did not take the dinner yet; the next \
                     sync retries it"
            | Error e -> die "the dinner is in the log but was not sent: %s" e))
    $ data_dir $ date $ label $ guests $ relays $ from $ hours)

let invite_expected =
  let guest =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"GUEST")
  in
  cmd "expected"
    "Record that a guest told you they installed, so their join is shown \
     rather than asked about. GUEST is their name or invite key."
    Term.(
      const (fun dir guest ->
          with_node dir (fun n ->
              let r = ok_or_die (Inv.Invite_node.expect n ~guest) in
              Printf.printf "%s\t%s\texpected\n" r.invite_key r.guest_name))
      $ data_dir $ guest)

let invite_list =
  cmd "list" "List this host's invites and what became of each."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (r : Inv.Host_watch.record) ->
                  Printf.printf "%s\t%s\t%s\t%s\n" r.invite_key r.guest_name
                    r.guest_email
                    (match r.state with
                    | Open Sent -> "sent"
                    | Open Expected -> "expected"
                    | Joined { identity_key; confirmed = true } ->
                        "joined " ^ identity_key
                    | Joined { identity_key; confirmed = false } ->
                        "joined, unconfirmed " ^ identity_key
                    | Revoked { identity_key } -> "revoked " ^ identity_key))
                (ok_or_die (Inv.Host_watch.load n.dir))))
      $ data_dir)

let invite =
  Cmd.group ~default:invite_create
    (Cmd.info "invite"
       ~doc:
         "Invite named guests to a dinner: sign the dinner with this device's \
          key, append it to every relay, keep a record per invite, and print \
          each guest's email with its mailto: link.")
    [ invite_expected; invite_list ]

let join =
  let text =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"INVITE"
          ~doc:"The invite text from the email, or its digestif://join link.")
  in
  let agent_name =
    Arg.(
      value
      & opt (some string) None
      & info [ "agent-name" ] ~docv:"NAME"
          ~doc:
            "Your agent's name on your card. The card's name is the one the \
             host gave you in the invite; digestif card changes either.")
  in
  cmd "join"
    "Join a circle with an invite: read the recovery phrase from stdin, set \
     this machine up, read the dinner from the invite's relay, append the join \
     to every relay the dinner lists, and publish your card."
    Term.(
      const (fun dir text agent_name ->
          let code = ok_or_die (Inv.Invite_code.parse text) in
          with_node dir (fun n ->
              let w =
                ok_or_die
                  (Inv.Invite_node.join ?agent_name n ~code
                     ~phrase:(read_phrase ()))
              in
              List.iter
                (fun (relay, r) ->
                  Printf.printf "%s\t%s\n" relay
                    (match r with
                    | Ok (rc : Relay_client.receipt) -> "joined " ^ rc.hash
                    | Error e -> "error " ^ Relay_client.error_to_string e))
                w.appended;
              match sync_node n with
              | Ok _ -> ()
              | Error e -> die "joined, but the first sync failed: %s" e))
      $ data_dir $ text $ agent_name)

(* asks *)

let asks_list =
  let all = Arg.(value & flag & info [ "all" ] ~doc:"Include answered asks.") in
  Term.(
    const (fun dir all ->
        with_node dir (fun n ->
            let now = Time_fmt.now () in
            List.iter
              (fun (a : Asks.t) ->
                Printf.printf "%s\n  %s\n  %s\n  %s\n  %s\n\n" a.key a.title
                  a.detail
                  (String.concat "  "
                     (List.map
                        (fun (c : Asks.choice) ->
                          c.id
                          ^ (if c.id = a.recommended then " (recommended)"
                             else "")
                          ^ ": " ^ c.label)
                        a.options))
                  (match a.answer with
                  | Some x -> (
                      "answered " ^ x
                      ^
                      match a.answered_via with
                      | Some (Decision d) -> " by decision " ^ d
                      | Some Lapse -> " when it lapsed"
                      | Some Person | None -> "")
                  | None when Asks.lapsed ~now a ->
                      Printf.sprintf "lapsed at %s: %s stands; answer it now"
                        a.lapses_at a.on_no_answer
                  | None ->
                      Printf.sprintf "lapses at %s, then %s" a.lapses_at
                        a.on_no_answer))
              (Asks.list ~all n.log)))
    $ data_dir $ all)

let asks_answer =
  let key = Arg.(required & pos 0 (some string) None & info [] ~docv:"KEY") in
  let choice =
    Arg.(required & pos 1 (some string) None & info [] ~docv:"OPTION")
  in
  cmd "answer"
    "Answer an ask. Revoking a join reads the recovery phrase from stdin, \
     because only the identity key signs a revoke."
    Term.(
      const (fun dir key choice ->
          with_node dir (fun n ->
              let identity () = Node.identity_from_phrase n (read_phrase ()) in
              let answered =
                if Inv.Host_watch.invite_key_of_ask_key key <> None then
                  Inv.Invite_node.answer n ~key ~choice ~identity
                else
                  Result.map
                    (fun () -> None)
                    (Asks.record_answer n.log ~key choice)
              in
              match ok_or_die answered with
              | Some hash ->
                  Printf.printf "revoke %s; the next sync pushes it\n" hash
              | None -> Printf.printf "%s %s\n" key choice))
      $ data_dir $ key $ choice)

let asks =
  Cmd.group ~default:asks_list
    (Cmd.info "asks" ~doc:"What this node needs you to decide.")
    [ asks_answer; cmd "list" "List open asks." asks_list ]

(* the digestif:// handler *)

let url_plan dir =
  Url_handler.plan ~exe:(exe ())
    ~dir:(Option.value dir ~default:(Node.default_dir ()))

let url_print =
  cmd "print" "Print what the digestif:// handler installs and where."
    Term.(
      const (fun dir ->
          let p = url_plan dir in
          Printf.printf "# %s\n# %s\n%s" p.path p.source_path p.source)
      $ data_dir)

let url_install =
  cmd "install"
    "Make digestif://join links open digestif join: an applet in \
     ~/Applications on macOS, a desktop entry on Linux."
    Term.(
      const (fun dir ->
          let p = url_plan dir in
          ok_or_die (Url_handler.install p);
          print_endline p.path)
      $ data_dir)

let url_uninstall =
  cmd "uninstall" "Remove the digestif:// handler."
    Term.(
      const (fun dir -> ok_or_die (Url_handler.uninstall (url_plan dir)))
      $ data_dir)

(* the daemon and the service *)

module B = Digestif_web.Behaviors

let report_spawned =
  List.iter (fun (h, r) ->
      match r with
      | Ok pid ->
          Printf.printf "%s behavior %s\tspawned, pid %d\n" (Time_fmt.now ())
            (B.hook_name h) pid
      | Error e -> Printf.eprintf "%s behavior %s\n%!" (Time_fmt.now ()) e)

let report_finished =
  List.iter (fun (f : B.finished) ->
      Printf.printf "%s behavior %s\t%s after %.0fs\n" (Time_fmt.now ())
        (B.hook_name f.f_hook) f.status f.seconds)

(* A 5-second sleep that took longer than this means the machine slept. *)
let wake_threshold = 60.

let run =
  let interval =
    Arg.(
      value & opt int 300
      & info [ "interval" ] ~docv:"SECONDS" ~doc:"Seconds between syncs.")
  in
  let no_ui =
    Arg.(value & flag & info [ "no-ui" ] ~doc:"Do not serve the web UI.")
  in
  let no_update =
    Arg.(
      value & flag
      & info [ "no-self-update" ]
          ~doc:"Never check for or install a new release.")
  in
  cmd "run"
    "Run the node: sync every interval, at once when the machine wakes from \
     sleep and soon after the web UI signs something, and serve the web UI on \
     127.0.0.1. After each sync admit the mail key, settle asks, and write and \
     mail the daily digest when it is due. Check for a release once a day and \
     on wake, and after installing one exit, so the service manager starts the \
     new binary."
    Term.(
      const (fun dir interval port no_ui no_update base ->
          let stop = stop_on_signals () in
          let sync_wanted = Atomic.make false in
          let server =
            if no_ui then None
            else
              let n = Node.open_ (node_dir dir) in
              match Digestif_web.Server.start ~port n with
              | Error e ->
                  Node.close n;
                  Printf.eprintf "%s ui: %s\n%!" (Time_fmt.now ()) e;
                  None
              | Ok fd ->
                  Some
                    ( Digestif_web.Server.url n,
                      Thread.create
                        (fun () ->
                          Fun.protect
                            ~finally:(fun () -> Node.close n)
                            (fun () ->
                              Digestif_web.Server.serve
                                ~on_write:(fun () ->
                                  Atomic.set sync_wanted true)
                                ~stop:(fun () -> !stop)
                                n fd))
                        () )
          in
          (* Behaviors keep one node open for the daemon's life: their sessions and runs outlive a
             pass. *)
          let bnode = Node.open_ (node_dir dir) in
          Digestif_web.Store.init bnode.log;
          let behaviors =
            B.create ~digestif:(exe ()) ?api_url:(Option.bind server fst) bnode
          in
          (* The recalls the circle carried at the last sync, which the update pass counts. *)
          let circle_recalls = ref [] in
          let pass () =
            Atomic.set sync_wanted false;
            let stored = ref 0 in
            let sync n =
              let r = watch_joins n in
              Result.iter
                (fun (r : Sync.report) ->
                  List.iter
                    (fun (rr : Sync.relay_report) ->
                      stored := !stored + rr.stored)
                    r.relays)
                r;
              r
            in
            with_node dir (fun n ->
                match
                  Daily.run ~silence:Digestif_web.Api.silence_section ~sync n
                with
                | Ok (r, p) ->
                    report_sync r;
                    circle_recalls := p.release_recalls;
                    report_daily p
                | Error e -> Printf.eprintf "%s sync: %s\n" (Time_fmt.now ()) e);
            report_spawned (B.after_pass behaviors ~stored:!stored);
            flush stdout
          in
          let updates =
            U.Schedule.config ~base
              ~circle:(fun () -> !circle_recalls)
              ~dir:(node_dir dir) ()
          in
          (* A switch ends the process: the supervisor runs the new release on trial. *)
          let self_update ~woke =
            if not no_update then
              match
                U.Schedule.tick updates ~now:(Unix.gettimeofday ()) ~woke
              with
              | None -> ()
              | Some (result, lines) -> (
                  List.iter
                    (fun l ->
                      Printf.printf "%s update: %s\n" (Time_fmt.now ()) l)
                    lines;
                  flush stdout;
                  match result with
                  | U.Schedule.Switched v ->
                      Printf.printf
                        "%s update: exiting so the supervisor starts %s\n"
                        (Time_fmt.now ()) (U.Version.to_string v);
                      exit 0
                  | Moved_back (from, to_) ->
                      Printf.printf
                        "%s update: %s is recalled; exiting so the service \
                         manager starts %s\n"
                        (Time_fmt.now ()) (U.Version.to_string from)
                        (U.Version.to_string to_);
                      exit 0
                  | Not_switched -> ())
          in
          (* An install ends the process, so it waits for running behaviors to finish rather than
             cutting a nightly note short; a wake seen meanwhile is kept for the deferred check. *)
          let wake_owed = ref false in
          let self_update ~woke =
            let woke = woke || !wake_owed in
            if B.busy behaviors then wake_owed := woke
            else begin
              wake_owed := false;
              self_update ~woke
            end
          in
          pass ();
          (* The first pass opened the store, synced and started the UI: the supervisor may keep
             this release (Supervisor). *)
          U.Health.write (node_dir dir)
            {
              version = U.Version.to_string (U.Trust_root.version ());
              pid = Unix.getpid ();
              at = Unix.gettimeofday ();
            };
          self_update ~woke:false;
          (* Sleep in short steps and compare wall clocks: a jump means the machine slept, so sync
             now and look for a release. *)
          let last = ref (Unix.gettimeofday ()) in
          let tick = ref !last in
          while not !stop do
            (try Unix.sleepf 5.0 with Unix.Unix_error (Unix.EINTR, _, _) -> ());
            let now = Unix.gettimeofday () in
            let woke = now -. !tick >= wake_threshold in
            tick := now;
            if
              (not !stop)
              && (woke
                 || now -. !last >= float_of_int interval
                 || Atomic.get sync_wanted)
            then begin
              last := now;
              pass ()
            end;
            report_finished (B.reap behaviors);
            if not !stop then self_update ~woke
          done;
          B.stop_all behaviors;
          Node.close bnode;
          Option.iter (fun (_, th) -> Thread.join th) server)
      $ data_dir $ interval $ ui_port $ no_ui $ no_update $ feed)

(* behaviors *)

let hook_arg =
  Arg.(
    required
    & pos 0 (some (enum (List.map (fun (h, n) -> (n, h)) B.hooks))) None
    & info [] ~docv:"HOOK"
        ~doc:
          "$(b,nightly), run once a day after the member's fixed minute, or \
           $(b,read), run after a sync that stored something new.")

(* Sources (docs/behaviors.md, Command sources), through the local API so the CLI and the web UI
   check a source the same way. *)
let source_call n ~meth ~path body =
  Digestif_web.Store.init n.Node.log;
  let r = Digestif_web.Api.handle n ~meth ~path ~query:[] ~body in
  match (r.status, r.body) with
  | s, Some (`List l) when s < 300 -> Ok l
  | _, Some (`List (`Assoc e :: _)) -> (
      match List.assoc_opt "message" e with
      | Some (`String m) -> Error m
      | _ -> Error "refused")
  | s, _ -> Error (Printf.sprintf "status %d" s)

let print_sources l =
  List.iter
    (function
      | `Assoc f ->
          let s k =
            match List.assoc_opt k f with Some (`String v) -> v | _ -> ""
          in
          let paths =
            match List.assoc_opt "paths" f with
            | Some (`List p) ->
                String.concat " "
                  (List.filter_map
                     (function `String v -> Some v | _ -> None)
                     p)
            | _ -> ""
          in
          let selected =
            match List.assoc_opt "selected" f with
            | Some (`Bool true) -> "selected"
            | _ -> "-"
          in
          Printf.printf "%s\t%s\t%s\t%s\t%s\n" (s "id") (s "kind") selected
            (s "label") paths
      | _ -> ())
    l

let source_list =
  cmd "list"
    "Every source: id, kind, whether it is chosen, label, and what it reads."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              print_sources
                (ok_or_die (source_call n ~meth:"GET" ~path:[ "sources" ] None))))
      $ data_dir)

let source_add =
  let label =
    Arg.(
      required
      & opt (some string) None
      & info [ "label" ] ~docv:"LABEL"
          ~doc:"What to call the source; every line it yields carries it.")
  in
  let program =
    Arg.(
      required
      & opt (some string) None
      & info [ "command" ] ~docv:"PROGRAM"
          ~doc:"The program, by its absolute path.")
  in
  let args =
    Arg.(
      value & pos_all string []
      & info [] ~docv:"ARG"
          ~doc:
            "Arguments the program is run with, after $(b,--) when they start \
             with a dash. The node appends $(b,--since) UNIX_SECONDS.")
  in
  let select =
    Arg.(
      value & flag
      & info [ "select" ] ~doc:"Choose it as well, as the Sources page would.")
  in
  cmd "add"
    "Add a command source: a program the nightly run calls as PROGRAM ARG... \
     --since UNIX_SECONDS, reading one line per item from its stdout."
    Term.(
      const (fun dir label program args select ->
          with_node dir (fun n ->
              let body =
                `Assoc
                  [
                    ("label", `String label);
                    ( "command",
                      `List (List.map (fun a -> `String a) (program :: args)) );
                  ]
              in
              ignore
                (ok_or_die
                   (source_call n ~meth:"POST" ~path:[ "sources" ] (Some body)));
              if select then begin
                let id = Digestif_web.Sources.command_id label in
                let chosen =
                  List.filter_map
                    (fun (s : Digestif_web.Store.source) ->
                      if s.selected then Some s.id else None)
                    (Digestif_web.Store.sources n.log)
                in
                Digestif_web.Store.select_sources n.log (id :: chosen)
              end;
              print_sources
                (ok_or_die (source_call n ~meth:"GET" ~path:[ "sources" ] None))))
      $ data_dir $ label $ program $ args $ select)

let source_remove =
  let id =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"ID"
          ~doc:"The source's id, as $(b,digestif source list) shows it.")
  in
  cmd "remove" "Remove a command source."
    Term.(
      const (fun dir id ->
          with_node dir (fun n ->
              print_sources
                (ok_or_die
                   (source_call n ~meth:"DELETE" ~path:[ "sources"; id ] None))))
      $ data_dir $ id)

let behavior_set =
  let path =
    Arg.(
      required
      & pos 1 (some string) None
      & info [] ~docv:"EXECUTABLE" ~doc:"The behavior, by its absolute path.")
  in
  cmd "set"
    "Set the executable digestif run spawns for a hook (docs/behaviors.md)."
    Term.(
      const (fun dir h path ->
          with_node dir (fun n -> ok_or_die (B.set_executable n.log h path)))
      $ data_dir $ hook_arg $ path)

let behavior_unset =
  cmd "unset" "Spawn nothing for a hook."
    Term.(
      const (fun dir h -> with_node dir (fun n -> B.unset_executable n.log h))
      $ data_dir $ hook_arg)

let behavior_list =
  cmd "list"
    "Each hook's behavior, the fixed minute the nightly one runs after, and \
     the local date it last ran on."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (h, name) ->
                  Printf.printf "%s\t%s\n" name
                    (Option.value (B.executable n.log h) ~default:"-"))
                B.hooks;
              Printf.printf "nightly minute\t3:%02d\n" (B.minute n.log);
              Printf.printf "nightly last ran\t%s\n"
                (Option.value (B.last_date n.log) ~default:"never")))
      $ data_dir)

let behavior_run =
  cmd "run"
    "Spawn a hook's behavior now, as digestif run would, and wait for it. Its \
     output goes to behaviors/<hook>.log in the data directory. A nightly run \
     that exits 0 counts as tonight's run; one that fails counts as a try."
    Term.(
      const (fun dir h ->
          with_node dir (fun n ->
              Digestif_web.Store.init n.log;
              let t =
                B.create ~digestif:(exe ())
                  ?api_url:(Digestif_web.Server.url n)
                  n
              in
              ignore (ok_or_die (B.spawn t h));
              let finished = B.wait_all t in
              report_finished finished;
              print_endline (B.log_path t h);
              match finished with
              | [ { status = "exited 0"; _ } ] -> ()
              | _ -> exit 1))
      $ data_dir $ hook_arg)

(* A program named on the command line or in DIGESTIF_WRITER, as the node records it: a bare name
   is looked up on PATH and a relative path is taken from here, since the service runs from /. *)
let resolve_program p =
  let p = Digestif_web.Sources.untilde p in
  if String.contains p '/' then
    if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p
  else
    let dirs =
      String.split_on_char ':'
        (Option.value (Sys.getenv_opt "PATH") ~default:"")
    in
    List.find_map
      (fun d ->
        let f = Filename.concat d p in
        if d <> "" && Sys.file_exists f && not (Sys.is_directory f) then Some f
        else None)
      dirs
    |> function
    | Some f -> f
    | None -> die "%s is not on PATH" p

let writer_set =
  let path =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"PROGRAM"
          ~doc:"The writer: a path, or a name looked up on PATH.")
  in
  cmd "set"
    "Record the writer the preview note and Draft for me run \
     (docs/behaviors.md). DIGESTIF_WRITER, when set, still wins for that \
     process."
    Term.(
      const (fun dir path ->
          let path = resolve_program path in
          with_node dir (fun n ->
              ok_or_die (Digestif_web.Sources.set_writer n.log path));
          print_endline path)
      $ data_dir $ path)

let writer_unset =
  cmd "unset" "Record no writer: the preview is a plain draft, no Draft for me."
    Term.(
      const (fun dir ->
          with_node dir (fun n -> Digestif_web.Sources.unset_writer n.log))
      $ data_dir)

let writer_show =
  cmd "show" "The writer this node runs, or - for none."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              print_endline
                (Option.value (Digestif_web.Sources.writer n.log) ~default:"-")))
      $ data_dir)

(* The service runs the supervisor from the last healthy release (docs/releases.md). *)
let service_plan dir =
  let dir = node_dir dir in
  Service.plan
    ~exe:(U.Layout.binary_in (U.Layout.good_link dir))
    ~command:[ "supervise" ] ~dir
    ~path:(Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin")
    ()

let behaviors_arg =
  Arg.(
    value
    & opt (some dir) None
    & info [ "behaviors" ] ~docv:"DIR"
        ~doc:
          "The behaviors/ directory of the checkout this binary was built \
           from, to install beside it.")

(* Make this binary the node's release: the one it already lives in, or a local release staged from
   it and [behaviors] (tested like any release first). current and good both name it. *)
let adopt dir behaviors =
  let me = binary () in
  let releases =
    try Unix.realpath (U.Layout.releases_dir dir)
    with Unix.Unix_error _ -> U.Layout.releases_dir dir
  in
  let inside = Filename.dirname (Filename.dirname (Filename.dirname me)) in
  let name =
    if inside = releases && behaviors = None then
      Filename.basename (Filename.dirname (Filename.dirname me))
    else
      match
        U.Stage.local ~dir ~version:(U.Trust_root.version ()) ~binary:me
          ~behaviors ()
      with
      | Ok name -> name
      | Error (U.Stage.Retry e | U.Stage.Refuse e) -> die "%s" e
  in
  U.Trial.clear dir;
  U.Layout.point_current dir name;
  U.Layout.point_good dir name;
  name

let service_print =
  cmd "print"
    "Print the launchd plist or systemd unit and where it would be installed."
    Term.(
      const (fun dir ->
          let p = service_plan dir in
          Printf.printf "# %s\n%s" p.path p.contents)
      $ data_dir)

let service_install =
  cmd "install"
    "Make this binary the node's release (with --behaviors, the behaviors \
     beside it), then install and start the node as a per-user launchd agent \
     or systemd user service, with this shell's PATH. A DIGESTIF_WRITER set \
     here is recorded as the node's writer (digestif writer set), since the \
     service does not inherit it."
    Term.(
      const (fun dir behaviors ->
          (match Sys.getenv_opt "DIGESTIF_WRITER" with
          | Some w when String.trim w <> "" ->
              let w = resolve_program (String.trim w) in
              with_node dir (fun n ->
                  ok_or_die (Digestif_web.Sources.set_writer n.log w));
              Printf.printf "writer %s\n" w
          | _ -> ());
          let name = adopt (node_dir dir) behaviors in
          Printf.printf "release %s\n" name;
          let p = service_plan dir in
          ok_or_die (Service.install p);
          print_endline p.path)
      $ data_dir $ behaviors_arg)

let service_uninstall =
  cmd "uninstall" "Stop and remove the per-user service."
    Term.(
      const (fun dir -> ok_or_die (Service.uninstall (service_plan dir)))
      $ data_dir)

(* The conformance suite's node adapter (conformance/README.md, The node adapter contract): a throwaway node
   with the given device seed syncs the given relays and prints what it folded and read. *)
let conformance_sync =
  let home =
    Arg.(required & opt (some string) None & info [ "home" ] ~docv:"DIR")
  in
  let seed_file =
    Arg.(
      required
      & opt (some string) None
      & info [ "device-seed-file" ] ~docv:"FILE")
  in
  let relays =
    Arg.(non_empty & opt_all string [] & info [ "relay" ] ~docv:"URL")
  in
  let root =
    Arg.(value & opt (some string) None & info [ "root" ] ~docv:"HASH")
  in
  cmd "sync"
    "Sync a throwaway node holding the given device seed and print its fold, \
     feed, forks and gaps as JSON."
    Term.(
      const (fun home seed_file relays root ->
          let seed =
            String.trim
              (In_channel.with_open_bin seed_file In_channel.input_all)
          in
          let ks = Keystore.memory () in
          let key =
            match B64url.decode seed with
            | Ok s when String.length s = 32 ->
                ok_or_die (Crypto.signing_key_of_seed s)
            | _ -> die "%s does not hold a base64url 32-byte seed" seed_file
          in
          ok_or_die (Keystore.put_signing_key ks "device" key);
          let n = Node.open_ ~keystore:ks home in
          Log.set_config n.log Node.k_device (Keys.public key);
          List.iter (Log.add_relay n.log) relays;
          (match (root, Node.root n) with
          | Some r, _ -> Node.set_root n r
          | None, Some _ -> ()
          | None, None ->
              (* A test circle has no out-of-band root, so take the first relay's word for it. *)
              List.iter
                (fun url ->
                  if Node.root n = None then
                    match
                      Relay_client.circle Relay_client.curl ~base:url ~key
                    with
                    | Ok (`Assoc f) -> (
                        match List.assoc_opt "root" f with
                        | Some (`String r) -> Node.set_root n r
                        | _ -> ())
                    | _ -> ())
                relays);
          let r = ok_or_die (Sync.sync n) in
          let fold = r.fold in
          let keys =
            Hashtbl.fold
              (fun _ (k : Fold.key_state) acc -> k :: acc)
              fold.keys []
            |> List.sort (fun (a : Fold.key_state) b -> compare a.key b.key)
            |> List.map (fun (k : Fold.key_state) ->
                `Assoc
                  [
                    ("key", `String k.key);
                    ("role", `String (Bodies.role_to_string k.role));
                    ("identity", `String k.identity);
                    ("revoked", `Bool (k.revoked_by <> None));
                  ])
          in
          print_endline
            (Yojson.Safe.to_string
               (`Assoc
                  [
                    ("epoch", `Int fold.epoch);
                    ("keys", `List keys);
                    ( "feed",
                      `List
                        (List.map
                           (fun (row : Log.row) -> `String row.hash)
                           (View.feed n.log fold)) );
                    ( "faults",
                      `List
                        (List.map
                           (fun (f : View.fork) ->
                             `Assoc
                               [
                                 ("kind", `String "fork");
                                 ("author", `String f.author);
                                 ("seq", `Int f.seq);
                                 ( "hashes",
                                   `List
                                     (List.map (fun h -> `String h) f.hashes) );
                               ])
                           (View.forks n.log)) );
                    ( "gaps",
                      `List
                        (List.map
                           (fun (a, seqs) ->
                             `Assoc
                               [
                                 ("author", `String a);
                                 ( "missing",
                                   `List (List.map (fun s -> `Int s) seqs) );
                               ])
                           (View.gaps n.log fold)) );
                  ]));
          Node.close n)
      $ home $ seed_file $ relays $ root)

let main =
  Cmd.group
    (Cmd.info "digestif"
       ~version:(U.Version.to_string (U.Trust_root.version ()))
       ~doc:"The Digestif node: keys, the circle log and relay sync.")
    [
      Cmd.group
        (Cmd.info "phrase" ~doc:"Recovery phrases.")
        [ phrase_new; phrase_check ];
      init;
      keys;
      Cmd.group
        (Cmd.info "relay" ~doc:"The relays this node reads and writes.")
        [ relay_add; relay_remove; relay_list ];
      sync_cmd;
      invite;
      join;
      asks;
      log_cmd;
      show;
      faults;
      circle;
      post;
      card;
      Cmd.group
        (Cmd.info "device" ~doc:"Device and mail keys.")
        [ device_publish ];
      Cmd.group
        (Cmd.info "phone" ~doc:"Phones paired to this member.")
        [ phone_add ];
      Cmd.group
        (Cmd.info "ask" ~doc:"Asks the daily digest carries.")
        [ ask_add; ask_list ];
      Cmd.group
        (Cmd.info "digest" ~doc:"The daily digest.")
        [ digest_email; digest_hour ];
      revoke;
      retract;
      import;
      verify;
      run;
      ui_cmd;
      open_cmd;
      note_cmd;
      tick_cmd;
      Cmd.group
        (Cmd.info "source"
           ~doc:"What the nightly note may read (docs/behaviors.md).")
        [ source_list; source_add; source_remove ];
      Cmd.group
        (Cmd.info "behavior"
           ~doc:"The programs digestif run spawns (docs/behaviors.md).")
        [ behavior_set; behavior_unset; behavior_list; behavior_run ];
      Cmd.group
        (Cmd.info "writer"
           ~doc:
             "The program the preview note and Draft for me run \
              (docs/behaviors.md).")
        [ writer_set; writer_unset; writer_show ];
      demo_cmd;
      Cmd.group
        (Cmd.info "update"
           ~doc:
             "Self-update: releases both release signers signed \
              (docs/releases.md).")
        [ update_check; update_apply; update_pin; update_unpin ];
      self_test;
      supervise;
      Cmd.group
        (Cmd.info "service" ~doc:"The launchd or systemd service.")
        [ service_print; service_install; service_uninstall ];
      Cmd.group
        (Cmd.info "url-handler"
           ~doc:"The digestif:// link handler that opens digestif join.")
        [ url_print; url_install; url_uninstall ];
      Cmd.group
        (Cmd.info "conformance" ~doc:"Adapters the conformance suite drives.")
        [ conformance_sync ];
    ]

let () = exit (Cmd.eval main)
