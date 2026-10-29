(* The digestif:// URL handler, so the join link in an invite email opens the node's join.

   macOS delivers a URL to an application bundle as an Apple Event, never as an argument, so the
   handler is a small AppleScript applet ("Digestif Join.app" in ~/Applications) that declares the
   scheme in its Info.plist and opens Terminal on `digestif join <url>`: the join reads the recovery
   phrase from the terminal. Linux registers a desktop entry for x-scheme-handler/digestif that runs
   the same command in a terminal. *)

let scheme = "digestif"
let bundle_id = "com.digestif.join"
let desktop_name = "digestif-join.desktop"

(* The command the handler runs, with the URL appended. *)
let join_argv ~exe ~dir = [ exe; "--data-dir"; dir; "join" ]

let applescript_string s =
  "\""
  ^ String.concat "\\\""
      (String.split_on_char '"'
         (String.concat "\\\\" (String.split_on_char '\\' s)))
  ^ "\""

let applescript ~exe ~dir =
  (* `quoted form of` makes each argument one shell word, the URL included. *)
  let words =
    String.concat " & \" \" & "
      (List.map
         (fun a -> "quoted form of " ^ applescript_string a)
         (join_argv ~exe ~dir))
  in
  String.concat "\n"
    [
      "on open location theURL";
      "  set cmd to " ^ words ^ " & \" \" & quoted form of theURL";
      "  tell application \"Terminal\"";
      "    activate";
      "    do script cmd";
      "  end tell";
      "end open location";
      "";
      "on run";
      "  display dialog \"Open a digestif://join link from an invite email to \
       join.\" buttons {\"OK\"} default button 1";
      "end run";
      "";
    ]

(* The desktop entry spec quotes an argument holding a reserved character in double quotes, with a
   backslash before each double quote, backtick, dollar sign and backslash inside them; a bare
   percent sign is doubled. *)
let desktop_quote s =
  let s = String.concat "%%" (String.split_on_char '%' s) in
  if String.exists (fun c -> String.contains " \t\n\"'\\><~|&;$*?#()`" c) s then begin
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter
      (fun c ->
        if String.contains "\"`$\\" c then Buffer.add_char b '\\';
        Buffer.add_char b c)
      s;
    Buffer.add_char b '"';
    Buffer.contents b
  end
  else s

let desktop_entry ~exe ~dir =
  String.concat "\n"
    [
      "[Desktop Entry]";
      "Type=Application";
      "Name=Digestif Join";
      "Comment=Join a Digestif circle from an invite link";
      "Exec="
      ^ String.concat " " (List.map desktop_quote (join_argv ~exe ~dir))
      ^ " %u";
      "Terminal=true";
      "NoDisplay=true";
      "MimeType=x-scheme-handler/" ^ scheme ^ ";";
      "";
    ]

let home () = Option.value (Sys.getenv_opt "HOME") ~default:"."

let lsregister =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

type plan = {
  path : string;  (** The app bundle on macOS, the desktop entry on Linux. *)
  source : string;
      (** What is written: the applet's script or the desktop entry. *)
  source_path : string;
  install : string array list;
  uninstall : string array list;
}

let plan ~exe ~dir =
  if Keystore.is_macos () then
    let app = Filename.concat (home ()) "Applications/Digestif Join.app" in
    let plist = Filename.concat app "Contents/Info.plist" in
    let src = Filename.concat dir "url-handler.applescript" in
    let buddy cmds =
      Array.of_list
        ([ "/usr/libexec/PlistBuddy" ]
        @ List.concat_map (fun c -> [ "-c"; c ]) cmds
        @ [ plist ])
    in
    {
      path = app;
      source = applescript ~exe ~dir;
      source_path = src;
      install =
        [
          [| "/bin/rm"; "-rf"; app |];
          [| "/usr/bin/osacompile"; "-o"; app; src |];
          buddy
            [
              "Add :CFBundleURLTypes array";
              "Add :CFBundleURLTypes:0 dict";
              "Add :CFBundleURLTypes:0:CFBundleURLName string " ^ bundle_id;
              "Add :CFBundleURLTypes:0:CFBundleURLSchemes array";
              "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string " ^ scheme;
            ];
          [| lsregister; "-f"; app |];
        ];
      uninstall = [ [| lsregister; "-u"; app |]; [| "/bin/rm"; "-rf"; app |] ];
    }
  else
    let data =
      match Sys.getenv_opt "XDG_DATA_HOME" with
      | Some d when d <> "" -> d
      | _ -> Filename.concat (home ()) ".local/share"
    in
    let apps = Filename.concat data "applications" in
    let path = Filename.concat apps desktop_name in
    {
      path;
      source = desktop_entry ~exe ~dir;
      source_path = path;
      install =
        [
          [|
            "xdg-mime"; "default"; desktop_name; "x-scheme-handler/" ^ scheme;
          |];
        ];
      uninstall = [ [| "/bin/rm"; "-f"; path |] ];
    }

let install p =
  Node.mkdir_p (Filename.dirname p.source_path);
  Out_channel.with_open_bin p.source_path (fun oc -> output_string oc p.source);
  Service.run_all p.install

let uninstall p = Service.run_all p.uninstall
