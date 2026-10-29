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
  cmd "add" "Add a relay."
    Term.(
      const (fun dir url -> with_node dir (fun n -> Log.add_relay n.log url))
      $ data_dir $ url)

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

let sync_cmd =
  cmd "sync"
    "Read every relay, verify and store what is new, fold, and push our \
     envelopes each relay lacks."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              let r = ok_or_die (Sync.sync n) in
              report_sync r;
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
                      @
                      match k.revoked_by with
                      | Some r -> [ ("revoked_by", `String r) ]
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
     the log; the next sync pushes it."
    Term.(
      const (fun dir kind body key ->
          with_node dir (fun n ->
              let hash, _ =
                ok_or_die
                  (Node.write n ~key_name:key ~kind (read_json_file body))
              in
              print_endline hash))
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
     from the phrase on stdin."
    Term.(
      const (fun dir target ->
          with_node dir (fun n ->
              let by =
                ok_or_die (Node.identity_from_phrase n (read_phrase ()))
              in
              print_endline
                (fst
                   (ok_or_die
                      (Node.write n ~kind:"revoke"
                         (Bodies.make_revoke ~by ~target))))))
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

(* the daily acts *)

let report_daily (p : Daily.report) =
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
          Printf.printf "ask %s\t%s\t%s\n" a.hash o.option
            (match o.source with Decided -> "decided" | Lapsed -> "lapsed")
      | None -> ())
    p.settled;
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
  cmd "add"
    "Queue an ask for the next digest. It is sealed to this member and \
     appended when the digest is written."
    Term.(
      const (fun dir file ->
          let ask =
            ok_or_die (Digestif_mail.Ask.of_plaintext (read_json_file file))
          in
          ok_or_die (Digestif_mail.Ask.validate ask);
          with_node dir (fun n -> Store.queue_ask n.log ask))
      $ data_dir $ file)

let ask_list =
  cmd "list"
    "List this member's asks: queued, open, or settled with the option acted \
     on."
    Term.(
      const (fun dir ->
          with_node dir (fun n ->
              List.iter
                (fun (_, (a : Digestif_mail.Ask.t)) ->
                  Printf.printf "queued\t%s\n" a.title)
                (Store.pending_asks n.log);
              List.iter
                (fun (a : Decisions.ask) ->
                  Printf.printf "%s\t%s\t%s%s\n" a.hash
                    (match a.outcome with
                    | Some { option; source = Decided; _ } ->
                        "decided " ^ option
                    | Some { option; source = Lapsed; _ } -> "lapsed " ^ option
                    | None -> "open until " ^ a.ask.lapses_at)
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
                ok_or_die (Phones.add n ~phrase:(read_phrase ()) ~code)
              in
              Printf.printf "%s\t%s\n" hash key))
      $ data_dir $ code)

(* the daemon and the service *)

let run =
  let interval =
    Arg.(
      value & opt int 300
      & info [ "interval" ] ~docv:"SECONDS" ~doc:"Seconds between syncs.")
  in
  cmd "run"
    "Run the node: sync every interval, and at once when the machine wakes \
     from sleep; after each sync admit the mail key, settle asks, and write \
     and mail the daily digest when it is due."
    Term.(
      const (fun dir interval ->
          let stop = ref false in
          List.iter
            (fun s ->
              Sys.set_signal s (Sys.Signal_handle (fun _ -> stop := true)))
            [ Sys.sigterm; Sys.sigint ];
          let pass () =
            with_node dir (fun n ->
                match Daily.run n with
                | Ok (r, p) ->
                    report_sync r;
                    report_daily p
                | Error e -> Printf.eprintf "%s sync: %s\n" (Time_fmt.now ()) e);
            flush stdout
          in
          pass ();
          (* Sleep in short steps and compare wall clocks: a jump means the machine slept, so sync now. *)
          let last = ref (Unix.gettimeofday ()) in
          while not !stop do
            (try Unix.sleepf 5.0 with Unix.Unix_error (Unix.EINTR, _, _) -> ());
            let now = Unix.gettimeofday () in
            if (not !stop) && now -. !last >= float_of_int interval then begin
              last := now;
              pass ()
            end
          done)
      $ data_dir $ interval)

let exe () =
  let e = Sys.executable_name in
  if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e

let service_plan dir =
  Service.plan ~exe:(exe ())
    ~dir:(Option.value dir ~default:(Node.default_dir ()))

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
    "Install and start the node as a per-user launchd agent or systemd user \
     service."
    Term.(
      const (fun dir ->
          let p = service_plan dir in
          ok_or_die (Service.install p);
          print_endline p.path)
      $ data_dir)

let service_uninstall =
  cmd "uninstall" "Stop and remove the per-user service."
    Term.(
      const (fun dir -> ok_or_die (Service.uninstall (service_plan dir)))
      $ data_dir)

(* The conformance suite's node adapter (conformance/README.md, Testing a node): a throwaway node
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
    (Cmd.info "digestif" ~version:"0.1.0"
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
      Cmd.group
        (Cmd.info "service" ~doc:"The launchd or systemd service.")
        [ service_print; service_install; service_uninstall ];
      Cmd.group
        (Cmd.info "conformance" ~doc:"Adapters the conformance suite drives.")
        [ conformance_sync ];
    ]

let () = exit (Cmd.eval main)
