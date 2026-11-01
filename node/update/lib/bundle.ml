(* What a release archive holds besides the binary: the parts of behaviors/ the node runs. Shared by
   the signer's `digestif-update bundle` and a local install, so both lay a release out alike. *)

let behavior_parts = [ "bin"; "src"; "prompts"; "package.json" ]
