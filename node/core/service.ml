(* Run the node as a per-user service: a launchd agent on macOS, a systemd user unit on Linux. The
   service runs `digestif run`, which syncs on an interval and whenever the machine wakes. It runs
   with the PATH of the shell that installed it, so the programs the node spawns (the writer, the
   behaviors, command sources, and the `node` and `claude` they run) resolve as they do there;
   launchd alone gives /usr/bin:/bin:/usr/sbin:/sbin. *)

(* The standard node's names (Node.is_standard). Every other node's service, unit and UI port are
   derived from its data directory, so a second node on the machine installs beside the first rather
   than replacing it. DIG-264 *)
let label = "com.digestif.node"
let unit_name = "digestif.service"
let standard_ui_port = 7420

(* A short name for a data directory: its base name in lower-case letters, digits and dashes, then
   eight hex digits of its path, so two directories with one base name differ. None for the
   standard node. *)
let slug dir =
  if Node.is_standard dir then None
  else
    let canonical = Node.canonical_dir dir in
    let b = Buffer.create 24 in
    String.iter
      (fun c ->
        let c = Char.lowercase_ascii c in
        if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then
          Buffer.add_char b c
        else if Buffer.length b > 0 && Buffer.nth b (Buffer.length b - 1) <> '-'
        then Buffer.add_char b '-')
      (Filename.basename canonical);
    let base = Buffer.contents b in
    let base = if String.length base > 24 then String.sub base 0 24 else base in
    let base =
      if base <> "" && base.[String.length base - 1] = '-' then
        String.sub base 0 (String.length base - 1)
      else base
    in
    let hash = String.sub (Crypto.sha256_hex canonical) 0 8 in
    Some (if base = "" then hash else base ^ "-" ^ hash)

let label_of dir =
  match slug dir with None -> label | Some s -> label ^ "." ^ s

let unit_name_of dir =
  match slug dir with
  | None -> unit_name
  | Some s -> "digestif-" ^ s ^ ".service"

(* The port a node's web UI listens on when --ui-port names none: 7420 for the standard node, and
   for any other one in 7421-7999 by its path. *)
let ui_port dir =
  if Node.is_standard dir then standard_ui_port
  else
    let h = Crypto.sha256_hex (Node.canonical_dir dir) in
    standard_ui_port + 1 + (int_of_string ("0x" ^ String.sub h 0 6) mod 579)

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
       "  <string>" ^ label_of dir ^ "</string>";
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
        (* Standard, not Background: launchd throttles a Background job's CPU and disk, and on a
           loaded machine that left the web UI answering nothing for minutes. DIG-323 *)
        "  <key>ProcessType</key>";
        "  <string>Standard</string>";
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

let launchd_path name =
  Filename.concat (home ()) ("Library/LaunchAgents/" ^ name ^ ".plist")

let systemd_path name =
  let config =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (home ()) ".config"
  in
  Filename.concat config ("systemd/user/" ^ name)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m > 0 && go 0

(* Whether a service file runs the node at [dir]. *)
let runs_dir ~contents dir =
  List.exists (contains contents)
    [
      "<string>--data-dir</string>\n    <string>" ^ xml_escape dir ^ "</string>";
      "--data-dir " ^ systemd_quote dir ^ "\n";
    ]

type plan = {
  path : string;
  contents : string;
  load : string array list;
  unload : string array list;
  loaded : string array list;
      (* Each exits 0 while the service manager still holds a job this plan unloads. launchd's
         bootout returns before the job is gone, and a bootstrap before then fails with 5. *)
  retire : string list;
      (* Service files this plan unloads and removes beside its own. *)
}

(* A node other than the standard one whose service was installed under the fixed names, before
   they were derived: that file runs this node, so installing the derived one retires it. A fixed
   file running another directory is the standard node's and is left alone. *)
let legacy ~fixed_path dir =
  if Node.is_standard dir then false
  else
    match In_channel.with_open_bin fixed_path In_channel.input_all with
    | contents ->
        runs_dir ~contents dir || runs_dir ~contents (Node.canonical_dir dir)
    | exception Sys_error _ -> false

let launchd_plan ?command ~exe ~dir ~path () =
  let name = label_of dir in
  let file = launchd_path name in
  let domain = "gui/" ^ string_of_int (Unix.getuid ()) in
  let bootout l = [| "/bin/launchctl"; "bootout"; domain ^ "/" ^ l |] in
  let probe l = [| "/bin/launchctl"; "print"; domain ^ "/" ^ l |] in
  let fixed = launchd_path label in
  let old = if legacy ~fixed_path:fixed dir then [ label ] else [] in
  {
    path = file;
    contents = launchd_plist ?command ~exe ~dir ~log_dir:dir ~path ();
    load = [ [| "/bin/launchctl"; "bootstrap"; domain; file |] ];
    unload = List.map bootout (old @ [ name ]);
    loaded = List.map probe (old @ [ name ]);
    retire = (if old = [] then [] else [ fixed ]);
  }

let systemd_plan ?command ~exe ~dir ~path () =
  let name = unit_name_of dir in
  let fixed = systemd_path unit_name in
  let old = if legacy ~fixed_path:fixed dir then [ unit_name ] else [] in
  {
    path = systemd_path name;
    contents = systemd_unit ?command ~exe ~dir ~path ();
    load =
      [
        [| "systemctl"; "--user"; "daemon-reload" |];
        [| "systemctl"; "--user"; "enable"; "--now"; name |];
      ];
    unload =
      List.map
        (fun u -> [| "systemctl"; "--user"; "disable"; "--now"; u |])
        (old @ [ name ]);
    loaded = [];
    retire = (if old = [] then [] else [ fixed ]);
  }

let plan ?command ~exe ~dir ~path () =
  if Keystore.is_macos () then launchd_plan ?command ~exe ~dir ~path ()
  else systemd_plan ?command ~exe ~dir ~path ()

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

let remove f = try Sys.remove f with Sys_error _ -> ()

(* Each command runs whatever the one before it answered: one job missing does not keep the next
   from being unloaded. *)
let run_each cmds = List.iter (fun argv -> ignore (run_all [ argv ])) cmds

let install p =
  Node.mkdir_p (Filename.dirname p.path);
  run_each p.unload;
  List.iter remove p.retire;
  Out_channel.with_open_bin p.path (fun oc -> output_string oc p.contents);
  match
    List.fold_left
      (fun acc probe ->
        match acc with Error _ -> acc | Ok () -> wait_until_gone probe)
      (Ok ()) p.loaded
  with
  | Error e -> Error e
  | Ok () -> run_all p.load

(* Rewrite an installed service file whose contents differ from the plan's, so a release that
   changes the file reaches nodes installed before it; the service manager reads it at the next
   load. Answers whether it wrote. A missing file is left missing: only an install creates one. *)
let refresh p =
  match In_channel.with_open_bin p.path In_channel.input_all with
  | exception Sys_error _ -> Ok false
  | current when current = p.contents -> Ok false
  | _ -> (
      try
        Out_channel.with_open_bin p.path (fun oc -> output_string oc p.contents);
        Ok true
      with Sys_error e -> Error e)

(* The plan's own job answers for the uninstall; a retired one is unloaded too, whatever it says. *)
let uninstall p =
  let r =
    match List.rev p.unload with
    | own :: old ->
        run_each (List.rev old);
        run_all [ own ]
    | [] -> Ok ()
  in
  List.iter remove (p.path :: p.retire);
  r
