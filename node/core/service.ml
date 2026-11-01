(* Run the node as a per-user service: a launchd agent on macOS, a systemd user unit on Linux. The
   service runs `digestif run`, which syncs on an interval and whenever the machine wakes. It runs
   with the PATH of the shell that installed it, so the programs the node spawns (the writer, the
   behaviors, command sources, and the `node` and `claude` they run) resolve as they do there;
   launchd alone gives /usr/bin:/bin:/usr/sbin:/sbin. *)

let label = "com.digestif.node"
let unit_name = "digestif.service"

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

let launchd_plist ?(command = [ "run" ]) ~exe ~dir ~log_dir ~path () =
  let args = (exe :: command) @ [ "--data-dir"; dir ] in
  String.concat "\n"
    ([
       {|<?xml version="1.0" encoding="UTF-8"?>|};
       {|<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">|};
       {|<plist version="1.0">|};
       "<dict>";
       "  <key>Label</key>";
       "  <string>" ^ label ^ "</string>";
       "  <key>ProgramArguments</key>";
       "  <array>";
     ]
    @ List.map (fun a -> "    <string>" ^ xml_escape a ^ "</string>") args
    @ [
        "  </array>";
        "  <key>EnvironmentVariables</key>";
        "  <dict>";
        "    <key>PATH</key>";
        "    <string>" ^ xml_escape path ^ "</string>";
        "  </dict>";
        "  <key>RunAtLoad</key>";
        "  <true/>";
        "  <key>KeepAlive</key>";
        "  <true/>";
        "  <key>ProcessType</key>";
        "  <string>Background</string>";
        "  <key>StandardOutPath</key>";
        "  <string>"
        ^ xml_escape (Filename.concat log_dir "digestif.log")
        ^ "</string>";
        "  <key>StandardErrorPath</key>";
        "  <string>"
        ^ xml_escape (Filename.concat log_dir "digestif.log")
        ^ "</string>";
        "</dict>";
        "</plist>";
        "";
      ])

(* systemd quotes an argument containing spaces with double quotes. *)
let systemd_quote s =
  if String.exists (fun c -> c = ' ' || c = '"' || c = '\\') s then
    "\""
    ^ String.concat "\\\""
        (String.split_on_char '"'
           (String.concat "\\\\" (String.split_on_char '\\' s)))
    ^ "\""
  else s

(* systemd expands %-specifiers in Environment= and ExecStart=; %% is a literal %. *)
let systemd_escape s = String.concat "%%" (String.split_on_char '%' s)

let systemd_unit ?(command = [ "run" ]) ~exe ~dir ~path () =
  String.concat "\n"
    [
      "[Unit]";
      "Description=Digestif node";
      "After=network-online.target";
      "Wants=network-online.target";
      "";
      "[Service]";
      "Environment=" ^ systemd_quote (systemd_escape ("PATH=" ^ path));
      "ExecStart="
      ^ String.concat " "
          (List.map systemd_quote ((exe :: command) @ [ "--data-dir"; dir ]));
      "Restart=always";
      "RestartSec=30";
      "";
      "[Install]";
      "WantedBy=default.target";
      "";
    ]

let home () = Option.value (Sys.getenv_opt "HOME") ~default:"."

let launchd_path () =
  Filename.concat (home ()) ("Library/LaunchAgents/" ^ label ^ ".plist")

let systemd_path () =
  let config =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (home ()) ".config"
  in
  Filename.concat config ("systemd/user/" ^ unit_name)

type plan = {
  path : string;
  contents : string;
  load : string array list;
  unload : string array list;
  loaded : string array option;
      (* Exits 0 while the service manager still holds the job. launchd's bootout returns before
         the job is gone, and a bootstrap before then fails with 5. *)
}

let plan ?command ~exe ~dir ~path () =
  if Keystore.is_macos () then
    let file = launchd_path () in
    let domain = "gui/" ^ string_of_int (Unix.getuid ()) in
    {
      path = file;
      contents = launchd_plist ?command ~exe ~dir ~log_dir:dir ~path ();
      load = [ [| "/bin/launchctl"; "bootstrap"; domain; file |] ];
      unload = [ [| "/bin/launchctl"; "bootout"; domain ^ "/" ^ label |] ];
      loaded = Some [| "/bin/launchctl"; "print"; domain ^ "/" ^ label |];
    }
  else
    {
      path = systemd_path ();
      contents = systemd_unit ?command ~exe ~dir ~path ();
      load =
        [
          [| "systemctl"; "--user"; "daemon-reload" |];
          [| "systemctl"; "--user"; "enable"; "--now"; unit_name |];
        ];
      unload = [ [| "systemctl"; "--user"; "disable"; "--now"; unit_name |] ];
      loaded = None;
    }

let run_all cmds =
  List.fold_left
    (fun acc argv ->
      match acc with
      | Error _ -> acc
      | Ok () -> (
          match Proc.run argv with
          | Ok { code = 0; _ } -> Ok ()
          | Ok { code; stderr; _ } ->
              Error
                (Printf.sprintf "%s exited %d: %s" argv.(0) code
                   (String.trim stderr))
          | Error e -> Error e))
    (Ok ()) cmds

(* Polls [loaded] until it stops answering 0, for at most [timeout] seconds. *)
let wait_until_gone ?(timeout = 10.0) ?(interval = 0.1)
    ?(run : string array -> (Proc.result, string) result = fun a -> Proc.run a)
    loaded =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec go () =
    match run loaded with
    | Ok { Proc.code = 0; _ } ->
        if Unix.gettimeofday () >= deadline then
          Error
            (Printf.sprintf "%s still finds the service after %.0f seconds"
               (String.concat " " (Array.to_list loaded))
               timeout)
        else (
          Unix.sleepf interval;
          go ())
    | Ok _ | Error _ -> Ok ()
  in
  go ()

let install p =
  Node.mkdir_p (Filename.dirname p.path);
  ignore (run_all p.unload);
  Out_channel.with_open_bin p.path (fun oc -> output_string oc p.contents);
  match Option.map wait_until_gone p.loaded with
  | Some (Error e) -> Error e
  | Some (Ok ()) | None -> run_all p.load

let uninstall p =
  let r = run_all p.unload in
  (try Sys.remove p.path with Sys_error _ -> ());
  r
