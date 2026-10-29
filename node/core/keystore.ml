(* Where the node's private keys live: the macOS Keychain or the Linux Secret Service, never a plain
   file. Stored: the device key, the mail key, and the encryption key (cached because every read needs
   it). The identity key is never stored.

   Both backends are driven through their standard command-line tools with the secret on stdin, never
   on an argv: `security -i` reads its commands from stdin, and `secret-tool store` reads the secret
   from stdin. An item is addressed by service "digestif" and an account naming the key and the
   node's data directory, so two nodes on one machine (a test circle) do not collide. *)

type t = {
  backend : string;
  get : string -> (string option, string) result;
  put : string -> string -> (unit, string) result;
  delete : string -> (unit, string) result;
}

let service = "digestif"

let quote s =
  (* `security -i` splits on whitespace and honors double quotes with backslash escapes. *)
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      if c = '"' || c = '\\' then Buffer.add_char b '\\';
      Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let trim_nl s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\n' then String.sub s 0 (n - 1) else s

let keychain ~scope =
  let account name = name ^ "@" ^ scope in
  let get name =
    match
      Proc.run
        [|
          "/usr/bin/security";
          "find-generic-password";
          "-s";
          service;
          "-a";
          account name;
          "-w";
        |]
    with
    | Error e -> Error e
    | Ok { code = 0; stdout; _ } -> Ok (Some (trim_nl stdout))
    | Ok { code = 44; _ } -> Ok None
    | Ok { code; stderr; _ } ->
        Error
          (Printf.sprintf "Keychain read failed (%d): %s" code
             (String.trim stderr))
  in
  let put name secret =
    let cmd =
      String.concat " "
        [
          "add-generic-password";
          "-U";
          "-s";
          quote service;
          "-a";
          quote (account name);
          "-l";
          quote ("Digestif " ^ name);
          "-w";
          quote secret;
        ]
    in
    match Proc.run ~stdin:(cmd ^ "\n") [| "/usr/bin/security"; "-i" |] with
    | Error e -> Error e
    | Ok { code = 0; stderr = ""; _ } -> (
        match get name with
        | Ok (Some v) when v = secret -> Ok ()
        | _ -> Error "Keychain write did not take")
    | Ok { code; stderr; _ } ->
        Error
          (Printf.sprintf "Keychain write failed (%d): %s" code
             (String.trim stderr))
  in
  let delete name =
    match
      Proc.run
        [|
          "/usr/bin/security";
          "delete-generic-password";
          "-s";
          service;
          "-a";
          account name;
        |]
    with
    | Ok { code = 0 | 44; _ } -> Ok ()
    | Ok { code; stderr; _ } ->
        Error
          (Printf.sprintf "Keychain delete failed (%d): %s" code
             (String.trim stderr))
    | Error e -> Error e
  in
  { backend = "macOS Keychain"; get; put; delete }

let secret_service ~scope =
  let attrs name = [| "service"; service; "account"; name ^ "@" ^ scope |] in
  let get name =
    match
      Proc.run (Array.append [| "secret-tool"; "lookup" |] (attrs name))
    with
    | Error e -> Error (e ^ " (install libsecret-tools)")
    | Ok { code = 0; stdout; _ } ->
        Ok (if stdout = "" then None else Some (trim_nl stdout))
    | Ok { code = 1; stderr = ""; _ } -> Ok None
    | Ok { code; stderr; _ } ->
        Error
          (Printf.sprintf "Secret Service read failed (%d): %s" code
             (String.trim stderr))
  in
  let put name secret =
    match
      Proc.run ~stdin:secret
        (Array.append
           [| "secret-tool"; "store"; "--label"; "Digestif " ^ name |]
           (attrs name))
    with
    | Error e -> Error (e ^ " (install libsecret-tools)")
    | Ok { code = 0; _ } -> Ok ()
    | Ok { code; stderr; _ } ->
        Error
          (Printf.sprintf "Secret Service write failed (%d): %s" code
             (String.trim stderr))
  in
  let delete name =
    match Proc.run (Array.append [| "secret-tool"; "clear" |] (attrs name)) with
    | Ok _ -> Ok ()
    | Error e -> Error e
  in
  { backend = "Secret Service"; get; put; delete }

(* For tests and for a throwaway circle on a CI box with no keyring. Never the default: it is a plain
   file, which the design rules out for a member's node. *)
let insecure_dir dir =
  let path name = Filename.concat dir (name ^ ".key") in
  let get name =
    let p = path name in
    if Sys.file_exists p then
      Ok (Some (In_channel.with_open_bin p In_channel.input_all))
    else Ok None
  in
  let put name secret =
    (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = Unix.openfile (path name) [ O_WRONLY; O_CREAT; O_TRUNC ] 0o600 in
    let oc = Unix.out_channel_of_descr fd in
    output_string oc secret;
    close_out oc;
    Ok ()
  in
  let delete name =
    (try Sys.remove (path name) with Sys_error _ -> ());
    Ok ()
  in
  { backend = "insecure file (" ^ dir ^ ")"; get; put; delete }

let memory () =
  let h = Hashtbl.create 4 in
  {
    backend = "memory";
    get = (fun n -> Ok (Hashtbl.find_opt h n));
    put =
      (fun n v ->
        Hashtbl.replace h n v;
        Ok ());
    delete =
      (fun n ->
        Hashtbl.remove h n;
        Ok ());
  }

let is_macos () =
  Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist"

(* DIGESTIF_INSECURE_KEYSTORE_DIR selects the plain-file store, for tests only. *)
let default ~scope =
  match Sys.getenv_opt "DIGESTIF_INSECURE_KEYSTORE_DIR" with
  | Some d when d <> "" -> insecure_dir d
  | _ -> if is_macos () then keychain ~scope else secret_service ~scope

(* Keys are stored as their 32-byte seed or secret, base64url. *)
let get_signing_key ks name =
  match ks.get name with
  | Error e -> Error e
  | Ok None -> Ok None
  | Ok (Some v) -> (
      match B64url.decode v with
      | Ok seed when String.length seed = 32 ->
          Result.map Option.some (Crypto.signing_key_of_seed seed)
      | _ ->
          Error (Printf.sprintf "%s holds a malformed %s key" ks.backend name))

let put_signing_key ks name (k : Crypto.signing_key) =
  ks.put name (B64url.encode k.seed)

let get_encryption_key ks name =
  match ks.get name with
  | Error e -> Error e
  | Ok None -> Ok None
  | Ok (Some v) -> (
      match B64url.decode v with
      | Ok s when String.length s = 32 ->
          Result.map Option.some (Crypto.encryption_key_of_secret s)
      | _ ->
          Error (Printf.sprintf "%s holds a malformed %s key" ks.backend name))

let put_encryption_key ks name (k : Crypto.encryption_key) =
  ks.put name (B64url.encode k.secret)
