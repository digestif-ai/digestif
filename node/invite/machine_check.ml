(* What Digestif needs on this machine that its release archive cannot carry, checked right after
   install and before the coding agents, so a machine that cannot hold the node's keys or run its
   service stops setup with the invite unspent (docs/design.md, Install).

   The keystore is checked by storing, reading and deleting a test key through the same Keystore the
   node uses. On Linux `systemctl --user` is checked too, since the service is a systemd user unit. A
   failure names what is missing and the one command for it. *)

open Digestif_core

type line = {
  label : string;  (** "Keychain", "Secret Service", "systemd" *)
  what : string;  (** "login keychain", "systemctl --user" *)
  ok : bool;
  detail : string;
      (** On success what it did ("stores and reads a key"); on failure why,
          followed by the one fix. *)
}

let test_key = "setup-check"

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m = 0 || go 0

(* Over SSH, or with no GUI session, the macOS login keychain is usually locked, and `security`
   answers that user interaction is not allowed. *)
let locked_keychain err =
  contains err "User interaction is not allowed"
  || contains err "(36)" || contains err "(51)"
  || contains (String.lowercase_ascii err) "locked"

let keychain_failure ~ssh err =
  if locked_keychain err || ssh then
    "The login keychain is locked, as it usually is over SSH. Unlock it, then \
     run the same command again:\n\
    \    security unlock-keychain ~/Library/Keychains/login.keychain-db"
  else
    "The login keychain did not store a key (" ^ err
    ^ "). Open Keychain Access, make sure the login keychain is unlocked, then \
       run the same command again."

let secret_service_failure err =
  let missing_tool =
    contains err "secret-tool:" && contains err "No such file"
  in
  (if missing_tool then "secret-tool is not installed."
   else
     "No Secret Service answered (" ^ err
     ^ "). A desktop session has one; a headless machine or an SSH session \
        usually has none.")
  ^ " Digestif keeps its keys in a Secret Service: install secret-tool and \
     GNOME Keyring, and keep the keyring running and unlocked for this user \
     whenever the service runs, which loginctl enable-linger alone does not \
     give:\n\
    \    sudo apt install libsecret-tools gnome-keyring\n\
     Then run the same command again."

let keystore ?(ssh = false) ~macos (ks : Keystore.t) =
  let label, what =
    if macos then ("Keychain", "login keychain")
    else ("Secret Service", "secret-tool")
  in
  let fail err =
    {
      label;
      what;
      ok = false;
      detail =
        (if macos then keychain_failure ~ssh err else secret_service_failure err);
    }
  in
  let value = B64url.encode (Crypto.random 16) in
  match ks.put test_key value with
  | Error e -> fail e
  | Ok () -> (
      let read = ks.get test_key in
      ignore (ks.delete test_key);
      match read with
      | Error e -> fail e
      | Ok (Some v) when v = value ->
          { label; what; ok = true; detail = "stores and reads a key" }
      | Ok _ -> fail "the key read back was not the key stored")

(* The systemd user manager the service unit runs under. *)
let systemd_user ~(run : string array -> (Proc.result, string) result) =
  let label = "systemd" and what = "systemctl --user" in
  let fix =
    "Digestif runs as a systemd user service, and systemctl --user could not \
     reach your user manager"
  in
  match run [| "systemctl"; "--user"; "show-environment" |] with
  | Ok { code = 0; _ } ->
      { label; what; ok = true; detail = "runs user services" }
  | Ok { stderr; _ } ->
      {
        label;
        what;
        ok = false;
        detail =
          fix ^ " (" ^ String.trim stderr
          ^ "). Log in to a session that starts one, or run:\n\
            \    loginctl enable-linger $USER\n\
             Then run the same command again.";
      }
  | Error e ->
      {
        label;
        what;
        ok = false;
        detail =
          fix ^ " (" ^ e
          ^ "). Digestif needs systemd on Linux; run it on a machine that has \
             it.";
      }

let in_ssh () =
  List.exists
    (fun v -> match Sys.getenv_opt v with Some s -> s <> "" | None -> false)
    [ "SSH_CONNECTION"; "SSH_TTY" ]

(* Every check, in order. [macos] picks the backend wording and whether systemd is checked. *)
let run ?(run = fun argv -> Proc.run ~timeout:20.0 argv) ?(ssh = in_ssh ())
    ~macos ks =
  keystore ~ssh ~macos ks :: (if macos then [] else [ systemd_user ~run ])

let all_ok = List.for_all (fun l -> l.ok)
