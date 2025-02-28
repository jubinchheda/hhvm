(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)
open Hh_prelude
module PositionedTree =
  Full_fidelity_syntax_tree.WithSyntax (Full_fidelity_positioned_syntax)
module St = Full_fidelity_source_text
module T = Extract_classish_types

let placeholder_name = "Placeholder_"

let interface_body_of_methods source_text T.{ selected_methods; _ } : string =
  let open Aast_defs in
  let abstractify_one meth =
    let stmts = meth.m_body.fb_ast in
    match List.hd stmts with
    | Some (stmt_pos, _) when not (Pos.equal stmt_pos Pos.none) ->
      let body_until_first_statement_length =
        Pos.start_offset stmt_pos - Pos.start_offset meth.m_span
      in
      St.sub_of_pos
        source_text
        ~length:body_until_first_statement_length
        meth.m_span
      |> String.rstrip ~drop:(fun ch ->
             Char.is_whitespace ch || Char.equal ch '{')
      |> Fn.flip ( ^ ) ";"
    | Some _
    | None ->
      St.sub_of_pos source_text meth.m_span
      |> String.rstrip ~drop:(fun ch ->
             Char.is_whitespace ch || Char.equal ch '}')
      |> String.rstrip ~drop:(fun ch ->
             Char.is_whitespace ch || Char.equal ch '{')
      |> Fn.flip ( ^ ) ";"
  in
  selected_methods |> List.map ~f:abstractify_one |> String.concat ~sep:"\n"

let format_classish path ~(body : string) : string =
  let classish = Printf.sprintf "interface %s {%s}" placeholder_name body in
  let prefixed = "<?hh\n" ^ classish in
  let strip_prefix s =
    s
    |> String.split_lines
    |> (fun lines -> List.drop lines 1)
    |> String.concat ~sep:"\n"
  in
  prefixed
  |> St.make path
  |> PositionedTree.make
  |> Libhackfmt.format_tree
  |> strip_prefix
  |> Fn.flip ( ^ ) "\n\n"

(** Create text edit for "interface Placeholder_ { .... }" *)
let extracted_classish_text_edit source_text path candidate : Lsp.TextEdit.t =
  let range_of_extracted =
    Pos.shrink_to_start candidate.T.class_.Aast_defs.c_span
    |> Lsp_helpers.hack_pos_to_lsp_range ~equal:Relative_path.equal
  in
  let body = interface_body_of_methods source_text candidate in
  let text = format_classish path ~body in
  Lsp.TextEdit.{ range = range_of_extracted; newText = text }

(** Generate text edit like: "extends Placeholder_" *)
let update_implements_text_edit class_ : Lsp.TextEdit.t =
  match List.last class_.Aast.c_implements with
  | Some (pos, _) ->
    let range =
      pos
      |> Pos.shrink_to_end
      |> Lsp_helpers.hack_pos_to_lsp_range ~equal:Relative_path.equal
    in
    let text = Printf.sprintf ", %s" placeholder_name in
    Lsp.TextEdit.{ range; newText = text }
  | None ->
    let range =
      let extends_pos_opt =
        class_.Aast.c_extends |> List.hd |> Option.map ~f:fst
      in
      let c_name_pos = class_.Aast.c_name |> fst in
      extends_pos_opt
      |> Option.value ~default:c_name_pos
      |> Pos.shrink_to_end
      |> Lsp_helpers.hack_pos_to_lsp_range ~equal:Relative_path.equal
    in
    let text = Printf.sprintf "\n  implements %s" placeholder_name in
    Lsp.TextEdit.{ range; newText = text }

let edit_of_candidate source_text path candidate : Lsp.WorkspaceEdit.t =
  let edits =
    let extracted_edit =
      extracted_classish_text_edit source_text path candidate
    in
    let reference_edit = update_implements_text_edit candidate.T.class_ in
    [reference_edit; extracted_edit]
  in
  let changes = SMap.singleton (Relative_path.to_absolute path) edits in
  Lsp.WorkspaceEdit.{ changes }

let to_refactor source_text path candidate : Code_action_types.Refactor.t =
  let edit = lazy (edit_of_candidate source_text path candidate) in
  Code_action_types.Refactor.{ title = "Extract interface"; edit }

let to_refactors (source_text : Full_fidelity_source_text.t) path candidate :
    Code_action_types.Refactor.t list =
  [to_refactor source_text path candidate]
