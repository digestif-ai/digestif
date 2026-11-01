(* A downloaded artifact is checked against the size and hash both signers signed before anything on
   disk changes (Stage). *)

let verify_artifact (a : Release.artifact) bytes =
  if String.length bytes <> a.size then
    Error
      (Printf.sprintf "artifact for %s is %d bytes, the manifest says %d"
         a.platform (String.length bytes) a.size)
  else
    let got = Keys.hash_of_bytes bytes in
    if got <> a.sha256 then
      Error
        (Printf.sprintf "artifact for %s hashes to %s, the manifest says %s"
           a.platform got a.sha256)
    else Ok ()
