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

(* [env] is set in the service beside PATH: the machine's service carries DIGESTIF_CIRCLES when
   the shell that installed it named one, so its supervisor finds the circles that shell does.
   [launcher], when the node has installed one (Launcher), is the program launchd starts, with the
   node's command as its arguments: macOS keys a privacy grant to the program launchd starts, and
   the launcher sits at one path its bytes rarely leave. DIG-492 *)
let launchd_plist ?launcher ?(command = [ "run" ]) ?(env = []) ~exe ~dir
    ~log_dir ~path () =
  let args =
    Option.to_list launcher @ (exe :: command) @ [ "--data-dir"; dir ]
  in
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
      ]
    @ List.concat_map
        (fun (k, v) ->
          [
            "    <key>" ^ xml_escape k ^ "</key>";
            "    <string>" ^ xml_escape v ^ "</string>";
          ])
        env
    @ [
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

let systemd_unit ?(command = [ "run" ]) ?(env = []) ~exe ~dir ~path () =
  String.concat "\n"
    ([
       "[Unit]";
       "Description=Digestif node";
       "After=network-online.target";
       "Wants=network-online.target";
       "";
       "[Service]";
       "Environment=" ^ systemd_quote (systemd_escape ("PATH=" ^ path));
     ]
    @ List.map
        (fun (k, v) ->
          "Environment=" ^ systemd_quote (systemd_escape (k ^ "=" ^ v)))
        env
    @ [
        "ExecStart="
        ^ String.concat " "
            (List.map systemd_quote ((exe :: command) @ [ "--data-dir"; dir ]));
        "Restart=always";
        "RestartSec=30";
        "";
        "[Install]";
        "WantedBy=default.target";
        "";
      ])

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

let launchd_plan ?launcher ?command ?env ~exe ~dir ~path () =
  let name = label_of dir in
  let file = launchd_path name in
  let domain = "gui/" ^ string_of_int (Unix.getuid ()) in
  let bootout l = [| "/bin/launchctl"; "bootout"; domain ^ "/" ^ l |] in
  let probe l = [| "/bin/launchctl"; "print"; domain ^ "/" ^ l |] in
  let fixed = launchd_path label in
  let old = if legacy ~fixed_path:fixed dir then [ label ] else [] in
  {
    path = file;
    contents =
      launchd_plist ?launcher ?command ?env ~exe ~dir ~log_dir:dir ~path ();
    load = [ [| "/bin/launchctl"; "bootstrap"; domain; file |] ];
    unload = List.map bootout (old @ [ name ]);
    loaded = List.map probe (old @ [ name ]);
    retire = (if old = [] then [] else [ fixed ]);
  }

let systemd_plan ?command ?env ~exe ~dir ~path () =
  let name = unit_name_of dir in
  let fixed = systemd_path unit_name in
  let old = if legacy ~fixed_path:fixed dir then [ unit_name ] else [] in
  {
    path = systemd_path name;
    contents = systemd_unit ?command ?env ~exe ~dir ~path ();
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

(* [launcher] applies to launchd alone: systemd keeps no decision keyed to a program's path. *)
let plan ?launcher ?command ?env ~exe ~dir ~path () =
  if Keystore.is_macos () then
    launchd_plan ?launcher ?command ?env ~exe ~dir ~path ()
  else systemd_plan ?command ?env ~exe ~dir ~path ()

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

(* The machine's one service (DIG-347): the standard node's service runs `digestif supervise`,
   which runs every circle folder's node beside the standard one. Each per-node service DIG-264
   installed for a node the machine's service now runs is retired: its job unloaded and its file
   removed, so no node ever runs twice. *)

let index_from s i sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go i

(* Every [sub] in [s] replaced by [by]. *)
let replace_all ~sub ~by s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    match index_from s i sub with
    | Some j ->
        Buffer.add_string b (String.sub s i (j - i));
        Buffer.add_string b by;
        go (j + String.length sub)
    | None -> Buffer.add_string b (String.sub s i (String.length s - i))
  in
  go 0;
  Buffer.contents b

(* xml_escape undone; &amp; last, so an escaped entity stays what it was. *)
let xml_unescape s =
  s
  |> replace_all ~sub:"&lt;" ~by:"<"
  |> replace_all ~sub:"&gt;" ~by:">"
  |> replace_all ~sub:"&quot;" ~by:"\""
  |> replace_all ~sub:"&amp;" ~by:"&"

(* The words of a systemd ExecStart= line, as systemd_quote and systemd_escape wrote them. *)
let systemd_words line =
  let words = ref [] and b = Buffer.create 64 and quoted = ref false in
  let started = ref false in
  let n = String.length line in
  let i = ref 0 in
  let flush () =
    if !started then words := Buffer.contents b :: !words;
    Buffer.clear b;
    started := false
  in
  while !i < n do
    let c = line.[!i] in
    if c = '\\' && !i + 1 < n then (
      Buffer.add_char b line.[!i + 1];
      started := true;
      incr i)
    else if c = '"' then (
      quoted := not !quoted;
      started := true)
    else if c = '%' && !i + 1 < n && line.[!i + 1] = '%' then (
      Buffer.add_char b '%';
      started := true;
      incr i)
    else if c = ' ' && not !quoted then flush ()
    else (
      Buffer.add_char b c;
      started := true);
    incr i
  done;
  flush ();
  List.rev !words

let rec after_data_dir = function
  | "--data-dir" :: d :: _ -> Some d
  | _ :: rest -> after_data_dir rest
  | [] -> None

(* The data directory a launchd plist or systemd unit runs a node for, read from its own
   --data-dir argument. None when it names none. *)
let data_dir_of ~contents =
  let plist_marker = "<string>--data-dir</string>" in
  match index_from contents 0 plist_marker with
  | Some i -> (
      let from = i + String.length plist_marker in
      match index_from contents from "<string>" with
      | None -> None
      | Some j -> (
          let start = j + String.length "<string>" in
          match index_from contents start "</string>" with
          | None -> None
          | Some k ->
              Some (xml_unescape (String.sub contents start (k - start)))))
  | None ->
      String.split_on_char '\n' contents
      |> List.find_map (fun line ->
          let p = "ExecStart=" in
          let m = String.length p in
          if String.length line > m && String.sub line 0 m = p then
            after_data_dir
              (systemd_words (String.sub line m (String.length line - m)))
          else None)

(* A per-node service DIG-264 installed: its launchd label or systemd unit name, its file, and
   the data directory it runs. *)
type unit_file = { name : string; file : string; data_dir : string option }

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let ends_with ~suffix s =
  let n = String.length s and m = String.length suffix in
  n >= m && String.sub s (n - m) m = suffix

(* Every per-node service file on this machine: com.digestif.node.<slug>.plist in
   ~/Library/LaunchAgents, or digestif-<slug>.service among the systemd user units. The standard
   node's fixed names are never among them. *)
let per_node_units () =
  let dir, keep, name_of =
    if Keystore.is_macos () then
      ( Filename.dirname (launchd_path label),
        (fun f ->
          f <> label ^ ".plist"
          && starts_with ~prefix:(label ^ ".") f
          && ends_with ~suffix:".plist" f),
        fun f -> Filename.chop_suffix f ".plist" )
    else
      ( Filename.dirname (systemd_path unit_name),
        (fun f ->
          starts_with ~prefix:"digestif-" f && ends_with ~suffix:".service" f),
        Fun.id )
  in
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | files ->
      Array.to_list files |> List.sort compare |> List.filter keep
      |> List.map (fun f ->
          let file = Filename.concat dir f in
          let data_dir =
            match In_channel.with_open_bin file In_channel.input_all with
            | contents -> data_dir_of ~contents
            | exception Sys_error _ -> None
          in
          { name = name_of f; file; data_dir })

(* Unload a per-node service and remove its file. It answers only once the service manager no
   longer holds the job, so the node it ran is stopped before anything else runs it. *)
let retire u =
  let result =
    if Keystore.is_macos () then (
      let domain = "gui/" ^ string_of_int (Unix.getuid ()) in
      run_each [ [| "/bin/launchctl"; "bootout"; domain ^ "/" ^ u.name |] ];
      wait_until_gone [| "/bin/launchctl"; "print"; domain ^ "/" ^ u.name |])
    else (
      run_each [ [| "systemctl"; "--user"; "disable"; "--now"; u.name |] ];
      Ok ())
  in
  match result with
  | Error e -> Error e
  | Ok () ->
      remove u.file;
      if not (Keystore.is_macos ()) then
        run_each [ [| "systemctl"; "--user"; "daemon-reload" |] ];
      Ok ()
