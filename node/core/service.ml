(* Run the node as a per-user service: a launchd agent on macOS, a systemd user unit on Linux. The
   service runs `digestif run`, which syncs on an interval and whenever the machine wakes. *)

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

let launchd_plist ~exe ~dir ~log_dir =
  let args = [ exe; "run"; "--data-dir"; dir ] in
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

let systemd_unit ~exe ~dir =
  String.concat "\n"
    [
      "[Unit]";
      "Description=Digestif node";
      "After=network-online.target";
      "Wants=network-online.target";
      "";
      "[Service]";
      "ExecStart="
      ^ String.concat " "
          (List.map systemd_quote [ exe; "run"; "--data-dir"; dir ]);
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
}

let plan ~exe ~dir =
  if Keystore.is_macos () then
    let path = launchd_path () in
    let domain = "gui/" ^ string_of_int (Unix.getuid ()) in
    {
      path;
      contents = launchd_plist ~exe ~dir ~log_dir:dir;
      load = [ [| "/bin/launchctl"; "bootstrap"; domain; path |] ];
      unload = [ [| "/bin/launchctl"; "bootout"; domain ^ "/" ^ label |] ];
    }
  else
    {
      path = systemd_path ();
      contents = systemd_unit ~exe ~dir;
      load =
        [
          [| "systemctl"; "--user"; "daemon-reload" |];
          [| "systemctl"; "--user"; "enable"; "--now"; unit_name |];
        ];
      unload = [ [| "systemctl"; "--user"; "disable"; "--now"; unit_name |] ];
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

let install p =
  Node.mkdir_p (Filename.dirname p.path);
  ignore (run_all p.unload);
  Out_channel.with_open_bin p.path (fun oc -> output_string oc p.contents);
  run_all p.load

let uninstall p =
  let r = run_all p.unload in
  (try Sys.remove p.path with Sys_error _ -> ());
  r
